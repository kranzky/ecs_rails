# frozen_string_literal: true

module EcsRails
  # The catalogue: standard components that ship in the gem as concerns
  # (ADR-0018). A host application owns the constant and includes the concern:
  #
  #   class Relationship < ApplicationComponent
  #     include EcsRails::Catalogue::Relationship
  #   end
  #
  # `rails g ecs_rails:install` writes these one-line classes and the one
  # migration that creates their tables. The rest of the catalogue arrives with
  # Linear ECS-9; {Relationship} is the first entry, because ADR-0017 needs it.
  module Catalogue
    # The one component every `relates_to` is a row of (ADR-0017).
    #
    # A relationship is a labelled component (RFC-0014) whose single attribute is
    # a target: the slot is the relationship name, `target_id` points at the
    # other entity. All relationships in an application live in one
    # `relationships` table, created at install, so declaring one is pure Ruby:
    #
    #   class Post < ApplicationEntity
    #     relates_to :author, User        # a row with slot "author"
    #   end
    #
    #   post.author = user                # post.author_relationship.target = user
    #   post.author                       # => the User (ADR-0008 resolves the subclass)
    #
    # The table (architecture.md §2):
    #
    #   relationships (id, entity_id, slot, target_id, owner_model, exclusive, timestamps)
    #   UNIQUE (entity_id, slot)                               -- one target per name
    #   INDEX  (target_id, slot)                               -- inverse lookups (RFC-0015)
    #   UNIQUE (target_id, slot, owner_model) WHERE exclusive  -- has_one, DB-enforced
    #   FK entity_id -> entities ON DELETE CASCADE
    #   FK target_id -> entities ON DELETE NULLIFY
    #
    # `owner_model` is a denormalised copy of the owner's `entities.model`, so
    # the exclusivity index is per owner type (an Invoice and an OrderItem both
    # pointing at an Order under slot `order` must not collide) and the inverse
    # `has_many` of RFC-0015 has a cheap scope. `exclusive` is what
    # `relates_to :order, Order, unique: true` writes; the partial unique index
    # then rejects a second owner of the same model pointing at the same target
    # under the same slot — at most one Invoice per Order — with no index of its
    # own. Both are stamped before save from the owning entity and the slot's
    # declaration, never set by hand.
    #
    # The declared target class travels with the declaration as the slot option
    # `target_class_name` (RFC-0014), and {#target=} checks assignments against
    # it: `post.author = company` raises {EcsRails::InvalidRelationship}. The
    # database never enforced target *type* — the foreign key points at
    # `entities`, not at a per-type table — so this Ruby check is the type
    # system, and it is mandatory (ADR-0017).
    module Relationship
      extend Definition

      table "relationships"
      schema do |t|
        t.uuid    :target_id,   default: nil
        t.string  :owner_model, null: false
        t.boolean :exclusive,   default: false, null: false
        t.index %i[target_id slot]
        t.index %i[target_id slot owner_model], unique: true, where: "exclusive", name: "index_relationships_exclusive"
        t.foreign_key :target_id, on_delete: :nullify
      end

      included do
        # The pointed-at entity. The association targets the abstract entity
        # base, exactly as Component's `belongs_to :entity` does, and the loaded
        # row's `model` decides the subclass (ADR-0008) — so `post.author` is a
        # User. Optional: an unset relationship is a valid row-less virtual, and
        # a nullified one (target destroyed) is a valid row (ADR-0003 / ADR-0013).
        belongs_to :target, class_name: "ApplicationEntity", optional: true

        # RFC-0014 slot options, set by `relates_to` on the declaration: the
        # target type this slot points at, and whether the link is exclusive.
        slot_option :target_class_name
        slot_option :unique, default: false

        before_save :ecs_stamp_owner
      end

      # The entity class this relationship's slot was declared to point at.
      #
      # @return [Class<EcsRails::Entity>, nil] nil for a row whose owner no longer
      #   declares the slot
      def target_class
        target_class_name&.constantize
      end

      # Assigns the target, checking it against the declared target class first.
      #
      # @param value [EcsRails::Entity, nil]
      # @return [EcsRails::Entity, nil]
      # @raise [EcsRails::InvalidRelationship] if `value` is not an instance of
      #   the declared target class (or a subclass of it)
      def target=(value)
        expected = target_class
        if value && expected && !value.is_a?(expected)
          raise InvalidRelationship,
                "relates_to :#{slot} on #{entity&.class&.name || owner_model} points at " \
                "#{expected.name}; got #{value.class.name}"
        end

        super
      end

      private

      # The owner's discriminator and the slot's exclusivity, copied onto the
      # row so the database can enforce `unique: true` per owner type
      # (ADR-0017). Stamped on every save rather than preset on the virtual: a
      # preset would differ from the column default and make an untouched
      # virtual look dirty (RFC-0006), and a save is the only time the values
      # can matter.
      def ecs_stamp_owner
        owner = association(:entity).target || entity
        self.owner_model = owner.model if owner
        self.exclusive = unique ? true : false
      end
    end
  end
end
