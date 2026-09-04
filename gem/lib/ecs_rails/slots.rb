# frozen_string_literal: true

module EcsRails
  # Labelled (plural) components: the component-side half of RFC-0014, decided
  # by ADR-0015.
  #
  # A component type may be declared more than once on an entity under distinct
  # labels, each a singleton with its own prefixed reader:
  #
  #   class User < ApplicationEntity
  #     component PostalAddress                      # slot ""         → user.postal_address
  #     component PostalAddress, prefix: :business   # slot "business" → user.business_address
  #   end
  #
  # The `slot` column is the discriminator. Every component table carries one
  # (`string, null: false, default: ""`) and the unique index is on
  # `(entity_id, slot)`, so ADR-0005's one-per-entity guarantee generalises to
  # one-per-(entity, slot) with singular as the `""` special case. The DSL's
  # slot-scoped `has_one` and the lazy reader's slot preset live in
  # {EcsRails::DSL} and {EcsRails::Lazy}; this module is what the component
  # itself knows: its reader name, and the per-slot options its declaration
  # carried.
  module Slots
    # Mixed into {EcsRails::Component}.
    module Component
      extend ActiveSupport::Concern

      # Class-level: the reader-name derivation and the `slot_option` DSL.
      module ClassMethods
        # The entity reader for this component under `slot` — THE one place the
        # derivation lives. The default slot's reader is the bare singular
        # (`postal_address`), a labelled slot's is prefixed with the label
        # (`business_address`). {EcsRails::Registry::Declaration#reader_name},
        # the DSL, presence, preloading and the destroy-reset all read this, so
        # they cannot drift apart.
        #
        # @param slot [String, Symbol, nil] the slot label; `""`/`nil` is the
        #   default slot
        # @return [Symbol] the reader name
        def ecs_reader_name(slot = "")
          singular = model_name.singular
          slot.to_s.empty? ? singular.to_sym : :"#{slot}_#{singular}"
        end

        # Declares a per-slot option this component accepts from its
        # declaration site (RFC-0014, slot configuration).
        #
        # A catalogue component often needs to be configured *where it is
        # declared*, because the same class serves different roles on different
        # entities: `State` wants its allowed states, `Measurement` its unit.
        # The declaration passes them as extra keywords on `component`, and the
        # component reads them back through a generated instance method:
        #
        #   class State < ApplicationComponent
        #     slot_option :states, default: []
        #     validates :value, inclusion: { in: ->(state) { state.states } }
        #   end
        #
        #   class Order < ApplicationEntity
        #     component State, prefix: :fulfilment, states: %w[pending shipped]
        #   end
        #
        #   order.fulfilment_state.states   # => ["pending", "shipped"]
        #
        # Options are **declared, not inferred**: an unknown keyword on
        # `component` raises at declaration time (ADR-0004's fail-loud stance),
        # so a typo cannot silently configure nothing. The value is resolved per
        # instance through the owning entity's declaration — see
        # {EcsRails::Slots::Component#slot_options}.
        #
        # @param name [Symbol] the option name; becomes an instance method
        # @param default [Object] the value when the declaration omits it
        # @return [void]
        # @raise [ArgumentError] if `name` is already a method or a column on the
        #   component, since the generated reader would shadow it
        def slot_option(name, default: nil)
          name = name.to_sym
          if method_defined?(name) || private_method_defined?(name) || ecs_column?(name)
            raise ArgumentError,
                  "#{self.name}.slot_option :#{name} would shadow an existing " \
                  "##{name}; choose another name"
          end

          ecs_own_slot_option_defaults[name] = default
          define_method(name) { slot_options.fetch(name) }
        end

        # The names this component accepts as per-slot options, ancestry
        # included.
        #
        # @return [Array<Symbol>]
        def slot_option_names
          slot_option_defaults.keys
        end

        # Every accepted option with its default, ancestry included (a
        # subclass sees its parent's options and may add its own).
        #
        # @return [Hash{Symbol => Object}]
        def slot_option_defaults
          ancestors.reverse.each_with_object({}) do |ancestor, merged|
            own = ancestor.instance_variable_get(:@ecs_slot_option_defaults)
            merged.merge!(own) if own
          end
        end

        private

        def ecs_own_slot_option_defaults
          @ecs_slot_option_defaults ||= {}
        end

        # Is `name` a column? ActiveRecord defines attribute readers lazily, so
        # `method_defined?` alone misses them at class-load time. Reading the
        # columns here touches the schema (as `component` itself does a moment
        # later); without a connection — a bare `ruby -e` load — the check is
        # skipped rather than failing the load.
        def ecs_column?(name)
          attribute_names.include?(name.to_s)
        rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
          false
        end
      end

      # The entity reader this instance is reached through — `business_address`
      # for a `PostalAddress` in slot `"business"`.
      #
      # @return [Symbol]
      def ecs_reader_name
        self.class.ecs_reader_name(slot)
      end

      # The per-slot options in force for this instance: the defaults declared
      # with {ClassMethods#slot_option}, overridden by whatever the owning
      # entity's `component` declaration passed for this slot.
      #
      # Resolved through the owning entity's class, because the same component
      # class is declared with different options on different entities — there
      # is no class-level answer. Reached through the lazy reader (or a
      # relationship/preload) the entity is already in hand and this costs no
      # query; a component loaded standalone (`State.where(...)`) loads its
      # entity first, one query, which a system that needs options should
      # preload. An instance whose entity does not declare this (component,
      # slot) — orphaned data — answers with the defaults.
      #
      # @return [Hash{Symbol => Object}] frozen
      def slot_options
        defaults = self.class.slot_option_defaults
        owner = association(:entity).target || entity
        declaration = owner && owner.class.declaration_for(self.class, prefix: slot.presence)

        (declaration ? defaults.merge(declaration.slot_options) : defaults).freeze
      end
    end
  end
end
