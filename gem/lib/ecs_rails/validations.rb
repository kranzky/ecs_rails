# frozen_string_literal: true

module EcsRails
  # Validation error merging: `entity.valid?` reflects its components' validity,
  # and `entity.errors` reads naturally in a Rails form.
  #
  # Implements RFC-0007. Closes the gap RFC-0006 left explicit (see its "Status"
  # section): the save/save! contract was already atomic, but it held *by
  # accident* — the after_save cascade's `component.save!` raised, and `save`
  # rescued it. `valid?` itself did not yet know a dirty component was bad.
  #
  #   user = User.create!
  #   user.email.address = "not-an-email"
  #   user.valid?                       # => false        (now, not just on save)
  #   user.errors[:"email.address"]     # => ["is invalid"]
  #   user.errors.full_messages         # => ["Email address is invalid"]
  #   user.save                         # => false, and inserts nothing
  #
  # With this in place, `entity.save` returns false because `valid?` is false
  # *before* the cascade ever runs — the cascade's bang becomes belt-and-braces,
  # exactly as ActiveRecord's autosave is. See RFC-0006's `#save_dirty_components`.
  module Validations
    # Mixed into EcsRails::Entity.
    module Entity
      extend ActiveSupport::Concern

      included do
        # A single `validate` callback that walks the memo and merges. No `on:`,
        # so it runs in both the create and update contexts: an entity has no
        # mutable fields of its own (architecture.md §1), so the money path is
        # always a persisted-entity save whose only real work is a component's,
        # and validation must fire there too.
        validate :ecs_merge_component_errors
      end

      # Class-level hooks. `human_attribute_name` is a class method, and
      # `ActiveModel::Error.full_message` reaches it via `base.class`, so the
      # override that decouples the human label from the error key has to live
      # here rather than on the instance.
      module ClassMethods
        # Turns a component-namespaced error key into a readable label, so that
        # the *key* and the *full message* can diverge (RFC-0007):
        #
        #   errors[:"email.address"]   # machine-readable, namespaced by reader
        #   full_messages             # => "Email address is invalid"  (human)
        #
        # ActiveModel couples these: `full_message` is
        # "%{human_attribute_name(attribute)} %{message}", and the stock
        # `human_attribute_name("email.address")` rpartitions on the dot and
        # returns just "Address" — giving "Address is invalid", which drops the
        # component entirely. Humanising the *whole* dotted key instead
        # ("email.address" -> "email_address" -> "Email address") keeps the
        # component as a word and reads as one sentence, only the first word
        # capitalised — which is exactly the RFC's expected message and, notably,
        # *not* "Email Address" (deferring to the component's own
        # `human_attribute_name` would capitalise both).
        #
        # Guarded to component reader keys only, so this never hijacks an
        # unrelated dotted attribute a host app might introduce.
        def human_attribute_name(attribute, options = {})
          key = attribute.to_s
          reader, dot, rest = key.partition(".")

          return super if dot.empty? || rest.empty?
          return super unless ecs_component_reader?(reader)

          key.tr(".", "_").humanize
        end

        # Is `reader` the name of a component reader on this entity?
        #
        # Deliberately `method_defined?` and not the registry (`components`).
        # The registry is a mutable process-wide singleton that the Railtie
        # clears and repopulates on reload, and that sibling specs clear outright
        # — so `components` can transiently be empty for a fully-composed entity.
        # The generated reader is the durable artifact: the DSL defines it into an
        # included module at declaration time, and it survives a registry clear
        # (the same reason delegation keeps working across one). Since
        # `human_attribute_name` is a hot method every form field hits, this is
        # also the cheaper check.
        #
        # It can only ever matter for a dotted key, and the only dotted keys the
        # gem produces are component-namespaced error keys whose head is, by
        # construction, a real reader — so the looseness (any instance method
        # named `reader` would pass) is harmless.
        def ecs_component_reader?(reader)
          method_defined?(reader)
        end
      end

      private

      # Merges the errors of every component that deserves validating onto the
      # entity, namespaced by the component's reader (`email.address`).
      #
      # **Which components?** Exactly the ones in RFC-0006's memo — the ones the
      # caller has actually read on *this* instance — and of those, only the ones
      # that are dirty or already persisted (ADR-0003: a virtual, untouched
      # component is not validated at all). This is deliberately *not* a walk of
      # every declared component:
      #
      #   - Reading an unread component to validate it would materialise it (a
      #     SELECT, or a fresh virtual instance) — a side effect `valid?` must not
      #     have, and it would validate a component the caller never touched.
      #   - A *persisted* component the caller has not loaded on this instance is
      #     therefore not validated here. "if this row exists it must be
      #     well-formed" (ADR-0003) is a save-time guarantee the row's own
      #     validations keep; `valid?` speaks only to what is in front of it.
      #
      # So `valid?` has no side effects: it inserts nothing, dirties nothing, and
      # materialises no component that was never read. Pinned hard in
      # validation_spec.rb.
      #
      # ActiveModel clears the entity's errors at the top of every `valid?`
      # (`run_validations!` does `errors.clear`), and `component.valid?` clears
      # the component's own — so merging twice cannot double-count or leak state
      # across calls. Idempotent by construction.
      def ecs_merge_component_errors
        return unless @ecs_components

        @ecs_components.each do |reader, component|
          # Destroyed through the reader inside this same lifecycle — there is no
          # row to be well-formed, and the reader hands out a fresh virtual next.
          next if component.destroyed?
          next unless component.ecs_dirty? || component.persisted?

          # `valid?` (not `errors.any?`) so the component actually runs its
          # validations, in the same create/update context a save would use.
          next if component.valid?

          merge_component_errors(reader, component)
        end
      end

      # Copies one component's errors onto the entity. Each error is re-added
      # individually so the attribute can be re-namespaced (`address` ->
      # `email.address`) while the message is carried across verbatim; the human
      # label is then composed by the `human_attribute_name` override above.
      #
      # A component base error (`errors.add(:base, ...)`) has no attribute to
      # namespace, so it lands under the bare reader key.
      def merge_component_errors(reader, component)
        component.errors.each do |error|
          key = error.attribute == :base ? reader : :"#{reader}.#{error.attribute}"
          errors.add(key, error.message)
        end
      end
    end
  end
end
