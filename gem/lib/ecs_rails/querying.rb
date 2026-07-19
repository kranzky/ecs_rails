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
  module Querying
    # Entities that HAVE a row for `component_class` (RFC-0010). With
    # `conditions`, the row must also match them (hash equality, like `where`).
    #
    # Returns an ActiveRecord::Relation, chainable with `where`, `order`, `limit`,
    # and further `with_component` / `without_component` calls (which AND).
    def with_component(component_class, **conditions)
      all.where(ecs_component_exists_sql(component_class, conditions, negate: false))
    end

    # Entities that have NO row for `component_class` (RFC-0010). No conditions
    # form — "without a *matching* row" is ambiguous and unneeded (see the RFC's
    # Non-goals). A virtual/lazy component has no row, so it counts as absent,
    # which is the intuitive reading of "without" (ADR-0009).
    def without_component(component_class)
      all.where(ecs_component_exists_sql(component_class, {}, negate: true))
    end

    private

    # Builds the `EXISTS (...)` / `NOT EXISTS (...)` fragment for one component.
    #
    # The subquery is built from `component_class.where(conditions)` so that
    # ActiveRecord sanitises the condition values — they are treated as data,
    # never SQL, closing the injection hole (ADR-0011). The correlation is an
    # Arel column comparison, `component.entity_id = entities.id`, so it renders
    # as properly quoted identifiers against the OUTER entities table — never a
    # hand-built string.
    #
    # `arel_table` here is the entity class's own table (`entities`); the outer
    # query the fragment is appended to selects from that same table, so `id`
    # correlates to each candidate entity row.
    def ecs_component_exists_sql(component_class, conditions, negate:)
      ecs_validate_queryable_component!(component_class)

      subquery = component_class
                 .where(conditions)
                 .where(component_class.arel_table[:entity_id].eq(arel_table[primary_key]))
                 .select("1")

      keyword = negate ? "NOT EXISTS" : "EXISTS"
      "#{keyword} (#{subquery.to_sql})"
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
