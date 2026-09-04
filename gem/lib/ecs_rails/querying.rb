# frozen_string_literal: true

module EcsRails
  # The class/relation-level query DSL: filter entities by which components they
  # have.
  #
  # Implements RFC-0010, decided by ADR-0011. Surfaced by the demo, where every
  # list view hand-rolled a cross-component subquery whose correctness silently
  # rode the entity's default_scope.
  #
  #   Post.with_component(PublishState, state: "published")  # posts that HAVE a
  #                                                          # matching row
  #   User.without_component(Avatar)                         # users with NO avatar
  #   Post.with_component(Name).with_component(Avatar)       # AND — chainable
  #
  #   Product.with_component(Money, prefix: :price) { where("amount_cents < ?", 5000) }
  #   Product.with_component(Rating, "stars >= ?", 4)         # beyond equality (RFC-0018)
  #   Product.order_by_component(Money, :amount_cents, prefix: :price)   # cheapest first
  #
  # Extended into EcsRails::Entity, so these are class methods on every entity
  # class. ActiveRecord delegates class methods to relations (via `scoping`), so
  # `Post.where(...).with_component(...)` chains too: the method runs with `all`
  # returning the current relation, which already carries the entity-model scope.
  #
  # ## Why EXISTS, not JOIN (ADR-0011)
  #
  # Each call compiles to a correlated `EXISTS` / `NOT EXISTS` subquery rather
  # than a join: EXISTS matches an entity once (no duplicate rows), N calls are N
  # independent `AND EXISTS` clauses that compose without table aliasing, and
  # `NOT EXISTS` is the natural, NULL-safe form of "without" (unlike `NOT IN` or a
  # `LEFT JOIN ... IS NULL`).
  #
  # ## Why the entity-model scope is correct for free (ADR-0011)
  #
  # A component table is blind to entity type — `Name` has rows for Users *and*
  # Posts. The scope that keeps `Post.with_component(Name)` from returning Users
  # is NOT added by this DSL. It falls out of the method running on `all`, which
  # is Post's own default-scoped relation (`model = 'posts'`, ADR-0002). The DSL
  # only appends the `EXISTS` clause. Building from `unscoped` or from
  # `ApplicationEntity` would drop that scope and leak — so we build from `all`.
  #
  # ## Ordering is a different mechanism (RFC-0018)
  #
  # `EXISTS` is a boolean: it can filter on a component's value but cannot sort
  # by it. `order_by_component` adds a correlated **scalar** subquery to
  # `ORDER BY` — `(SELECT amount_cents FROM monies WHERE entity_id = entities.id
  # AND slot = 'price' LIMIT 1)` — which needs no join, no table alias, cannot
  # duplicate rows, and composes with every filter above. Entities without the
  # row sort last.
  module Querying
    # Entities that HAVE a row for `component_class` (RFC-0010). With
    # `conditions`, the row must also match them (hash equality, like `where`).
    #
    # Compiles to a correlated `EXISTS` subquery, so an entity matches once —
    # never duplicated as a join would. Condition values are sanitised by
    # ActiveRecord and treated as data, never SQL (ADR-0011).
    #
    # The component need *not* be declared on this entity: querying a component
    # the entity never declares is a valid, always-empty query, not an error.
    #
    # @example Filtering by a component's attributes
    #   Post.with_component(PublishState, state: "published")
    #
    # @example Chaining — each call ANDs
    #   Post.with_component(Title).with_component(Body).order(created_at: :desc)
    #
    # @example Filtering by slot (RFC-0014) — `prefix:` is sugar for `slot:`
    #   User.with_component(Address, prefix: :business, region: "WA")
    #   User.with_component(Address)   # any slot
    #
    # @example Beyond equality (RFC-0018): a block, run as the component's scope
    #   Product.with_component(Money, prefix: :price) { where("amount_cents < ?", 5000) }
    #   Post.with_component(Tags, prefix: :topics) { tagged("ruby") }        # a component scope
    #   Post.with_component(SearchVector) { matching("composable") }
    #
    # @example Beyond equality: `where`-style positional conditions
    #   Product.with_component(Rating, "stars >= ?", 4)
    #   Product.with_component(Rating, ["stars >= ?", 4])
    #
    # @param component_class [Class<EcsRails::Component>] a concrete component
    # @param where_args [Array] optional `where`-style conditions — a SQL
    #   fragment with binds, or an array of them — applied to the component row
    # @param prefix [Symbol, String, nil] a slot label, as the DSL spells it;
    #   equivalent to `slot: "label"`. Omitted: any slot.
    # @param conditions [Hash] optional attribute equality the row must match
    # @yield the component's relation, as `self` — call `where`, `where.not`,
    #   any of the component's own scopes; must return a relation
    # @return [ActiveRecord::Relation] chainable, and still scoped to this
    #   entity's own `model` discriminator (ADR-0002)
    # @raise [EcsRails::InvalidComponent] if `component_class` is not a concrete
    #   component, or is abstract and so owns no table
    # @raise [ArgumentError] if the block returns something other than a
    #   relation of the component
    # @see #without_component
    # @see #order_by_component
    # @see EcsRails::Relationships#with_related the relationship-name equivalent
    def with_component(component_class, *where_args, prefix: nil, **conditions, &block)
      conditions = ecs_slot_conditions(prefix).merge(conditions)
      all.where(ecs_component_exists_sql(component_class, conditions, negate: false,
                                                          where_args: where_args, refine: block))
    end

    # Orders entities by a component's column, via a correlated scalar subquery
    # in `ORDER BY` (RFC-0018). Entities without the row sort last, whatever the
    # direction, unless `nulls: :first`.
    #
    # Composes with `with_component` and the rest of ActiveRecord; several calls
    # order by several components in turn; `reorder` clears earlier orders as
    # usual. The entity-model scope is untouched: the subquery correlates on
    # this relation's rows and nothing else.
    #
    # @example Cheapest first, then top-rated
    #   Product.listed.order_by_component(Money, :amount_cents, prefix: :price)
    #   Product.listed.order_by_component(Rating, :stars, :desc)
    #
    # @example By a primary attribute — the column may be omitted
    #   Post.published.order_by_component(Counter, prefix: :likes, direction: :desc)
    #   Post.order_by_component(Text, prefix: :title)   # alphabetical by title
    #
    # @param component_class [Class<EcsRails::Component>] a concrete component
    # @param column [Symbol, String, nil] one of the component's columns; omit
    #   for the component's primary attribute
    # @param positional_direction [Symbol] `:asc` or `:desc`; also accepted as
    #   `direction:`, which wins when both are given
    # @param direction [Symbol, nil] the keyword spelling of the direction
    # @param prefix [Symbol, String, nil] a slot label; omitted means the
    #   default slot `""` — ordering needs ONE row per entity, so "any slot" is
    #   not an option here
    # @param nulls [Symbol] `:last` (default) or `:first` — where entities with
    #   no row go
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidComponent] if `component_class` is not a concrete
    #   component, or is abstract and so owns no table
    # @raise [ArgumentError] for an unknown column, a missing column on a
    #   component with no primary attribute, or a bad direction / nulls
    # @see #with_component
    def order_by_component(component_class, column = nil, positional_direction = :asc,
                           direction: nil, prefix: nil, nulls: :last)
      ecs_validate_queryable_component!(component_class)
      direction = (direction || positional_direction).to_sym
      column = ecs_order_column!(component_class, column)
      unless %i[asc desc].include?(direction)
        raise ArgumentError, "order_by_component: direction must be :asc or :desc, got #{direction.inspect}"
      end
      unless %i[first last].include?(nulls)
        raise ArgumentError, "order_by_component: nulls: must be :first or :last, got #{nulls.inspect}"
      end

      subquery = component_class
                 .where(slot: prefix.to_s)
                 .where(component_class.arel_table[:entity_id].eq(arel_table[primary_key]))
                 .select(component_class.arel_table[column])
                 .limit(1)

      all.order(Arel.sql("(#{subquery.to_sql}) #{direction.to_s.upcase} NULLS #{nulls.to_s.upcase}"))
    end

    # Entities that have NO row for `component_class` (RFC-0010).
    #
    # Compiles to `NOT EXISTS`, which is the NULL-safe form of "without" — unlike
    # `NOT IN` or a `LEFT JOIN ... IS NULL`.
    #
    # There is deliberately no conditions form: "without a *matching* row" is
    # ambiguous (see the RFC's Non-goals). A virtual/lazy component has no row, so
    # it counts as absent — the intuitive reading of "without" (ADR-0009).
    #
    # @example
    #   User.without_component(Avatar)
    #
    # @example No row in one slot (RFC-0014)
    #   User.without_component(PostalAddress, prefix: :business)
    #
    # @param component_class [Class<EcsRails::Component>] a concrete component
    # @param prefix [Symbol, String, nil] a slot label; omitted means no row in
    #   any slot
    # @return [ActiveRecord::Relation] chainable, entity-model scoped
    # @raise [EcsRails::InvalidComponent] if `component_class` is not a concrete
    #   component, or is abstract and so owns no table
    # @see #with_component
    def without_component(component_class, prefix: nil)
      all.where(ecs_component_exists_sql(component_class, ecs_slot_conditions(prefix), negate: true))
    end

    private

    # RFC-0014: `prefix: :business` reads as the DSL does and means
    # `slot: "business"`. The slot is an ordinary column, so this is the only
    # query surface slots need — pure spelling.
    def ecs_slot_conditions(prefix)
      prefix.nil? ? {} : { slot: prefix.to_s }
    end

    # Builds the `EXISTS (...)` / `NOT EXISTS (...)` fragment for one component.
    #
    # The subquery is built from `component_class.where(conditions)` so that
    # ActiveRecord sanitises the condition values — they are treated as data,
    # never SQL, closing the injection hole (ADR-0011). The correlation is an
    # Arel column comparison, `component.entity_id = entities.id`, so it renders
    # as properly quoted identifiers against the OUTER entities table — never a
    # hand-built string.
    #
    # `where_args` (RFC-0018) go through the component relation's own `where`,
    # so binds are sanitised exactly as in any `where("x > ?", n)`. `refine` is
    # the block form: instance_exec'd on the component relation so `where`,
    # `where.not` and the component's scopes read naturally, and checked to
    # return a relation of the component — anything else is a mistake that
    # would otherwise silently drop the refinement.
    #
    # `arel_table` here is the entity class's own table (`entities`); the outer
    # query the fragment is appended to selects from that same table, so `id`
    # correlates to each candidate entity row.
    def ecs_component_exists_sql(component_class, conditions, negate:, where_args: [], refine: nil)
      ecs_validate_queryable_component!(component_class)

      subquery = component_class.where(conditions)
      subquery = subquery.where(*where_args) unless where_args.empty?
      subquery = ecs_refine_component_scope(component_class, subquery, refine) if refine
      subquery = subquery
                 .where(component_class.arel_table[:entity_id].eq(arel_table[primary_key]))
                 .select("1")

      keyword = negate ? "NOT EXISTS" : "EXISTS"
      "#{keyword} (#{subquery.to_sql})"
    end

    # The block form of `with_component`: run as the component's relation, and
    # its result checked, because a block that returns e.g. an Integer or some
    # other class's relation would otherwise be dropped on the floor.
    def ecs_refine_component_scope(component_class, scope, block)
      refined = scope.instance_exec(&block)
      unless refined.is_a?(ActiveRecord::Relation) && refined.klass == component_class
        raise ArgumentError,
              "with_component(#{component_class.name}) { ... } must return a relation of " \
              "#{component_class.name} (got #{refined.class}); call where/scopes on the block's self"
      end

      refined
    end

    # The column to order by: the one given, validated against the component's
    # real columns (it is interpolated into SQL, so only a known column may pass),
    # or the component's primary attribute when none is given.
    def ecs_order_column!(component_class, column)
      column = column.nil? ? component_class.primary : column.to_sym
      if column.nil?
        raise ArgumentError,
              "order_by_component(#{component_class.name}): name a column — #{component_class.name} " \
              "declares no primary attribute"
      end
      unless component_class.column_names.include?(column.to_s)
        raise ArgumentError,
              "order_by_component: #{component_class.name} has no column #{column.inspect} " \
              "(columns: #{component_class.column_names.join(', ')})"
      end

      column
    end

    # A queryable component is any concrete EcsRails::Component. Unlike the
    # presence API (RFC-0009), it need NOT be declared on this entity: querying
    # `Post.with_component(Avatar)` when Post has no Avatar is a valid,
    # always-empty query, not an error (RFC-0010) — and keeps the DSL from
    # needing the registry. Anything that is not a concrete component raises
    # InvalidComponent, before any database work.
    def ecs_validate_queryable_component!(component_class)
      unless component_class.is_a?(Class) && component_class < EcsRails::Component
        raise InvalidComponent,
              "#{component_class.inspect} is not an EcsRails::Component subclass"
      end

      # An abstract component owns no table (architecture.md §1), so its EXISTS
      # subquery could never resolve. Fail here rather than at the database.
      return unless component_class.abstract_class?

      raise InvalidComponent,
            "#{component_class.name} is abstract and owns no table; " \
            "query a concrete component"
    end
  end
end
