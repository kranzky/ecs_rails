# frozen_string_literal: true

module EcsRails
  # The class-level DSL that composes an entity out of components.
  #
  # Implements RFC-0004. Extended into EcsRails::Entity, so every entity class —
  # and every subclass of one — answers `component`.
  #
  #   class User < ApplicationEntity
  #     component Name
  #     component Email
  #     component Group, except: [:title]
  #   end
  #
  #   User.components            # => [Name, Email, Group]
  #   User.create!.email         # => the Email row, or nil (see #component)
  #
  # Each declaration does three things: it records itself in the registry
  # (RFC-0002), it sets up the has_one that reads the component row, and it
  # ensures #generated_component_methods exists — the module RFC-0005's delegated
  # methods and RFC-0006's lazy reader are generated into.
  module DSL
    # Declares that this entity is composed from `component_class`.
    #
    # Defines a reader named for the component's model_name.singular, so
    # `component Email` gives `#email`.
    #
    # **The reader returns nil when the entity has no row for the component.**
    # RFC-0004 says it materialises an instance lazily, but that is RFC-0006's
    # job, and RFC-0006 is a sibling of RFC-0005 on top of this RFC rather than a
    # dependency of it — so this cannot rely on it. Until RFC-0006 lands the
    # reader is ActiveRecord's own has_one reader and the gem does not yet meet
    # architecture.md §3 ("entity.email always returns an Email instance"). See
    # the "the reader" section of spec/dsl_spec.rb.
    #
    # `only:` / `except:` restrict which of the component's methods are delegated
    # onto the entity (RFC-0005). They never affect the reader: `user.group`
    # exists whatever `except:` says. RFC-0004 validates and records them;
    # RFC-0005 acts on them.
    #
    # Deliberately no `dependent:` option on the has_one, contradicting RFC-0004
    # and matching architecture.md §3 and RFC-0003: cascade is owned by the
    # database. Every component table has an ON DELETE CASCADE FK to
    # entities(id), so entity.destroy already removes the rows, without loading a
    # single component. Declaring dependent: :destroy as well would put two
    # layers on one job — the ActiveRecord one masking the database one, so that
    # dropping the FK would break the invariant with every test still passing.
    # The price is that a component's own destroy callbacks do not run on
    # entity.destroy; that is a real gap, and it wants an ADR rather than a
    # has_one option.
    #
    # Raises InvalidComponent unless `component_class` is a concrete
    # EcsRails::Component; DuplicateComponent if this entity — or any entity it
    # inherits from — already declares it; ArgumentError for bad options or for
    # an anonymous class on either side.
    #
    # Returns the Registry::Declaration.
    def component(component_class, only: nil, except: nil)
      validate_component_class!(component_class)
      options = normalized_delegation_options(only: only, except: except)
      validate_not_inherited!(component_class)

      # Registered first, so that the registry's own duplicate check (RFC-0002)
      # is what stops a doubled `component` line — before any method is defined.
      declaration = EcsRails.registry.register(
        entity_class: self,
        component_class: component_class,
        options: options
      )

      define_component_association(component_class)

      # Must follow the has_one: see #generated_component_methods.
      generated_component_methods

      declaration
    end

    # Every component this entity is composed from, nearest ancestor last.
    def components
      component_declarations.map(&:component_class)
    end

    # Every declaration this entity is composed from, parent's before its own.
    #
    # RFC-0004 requires subclasses to inherit their parent's declarations. The
    # registry is not involved in that: it holds exactly what each class itself
    # declared, keyed by that class's own name (RFC-0002), and the walk happens
    # here on read. Copying declarations down into each subclass instead — which
    # is what RFC-0004's example test implies — would triple-count component
    # tables in #entities_for, miss anything the parent declares after the
    # subclass is defined, and duplicate a name-keyed store whose entire purpose
    # is to not hold stale copies.
    #
    # So EcsRails.registry.components_for(Admin) is only Admin's own, by design,
    # and this is the method that answers "what is an Admin made of".
    def component_declarations
      entity_ancestry.flat_map { |klass| EcsRails.registry.components_for(klass) }
    end

    # The module the DSL generates methods into: RFC-0005's delegated methods,
    # and RFC-0006's reader override. Empty in RFC-0004 — it exists here because
    # the DSL owns method generation, and because the include ordering below is
    # subtle enough to want pinning by tests now rather than in RFC-0006.
    #
    # ADR-0004 requires generated methods to live in an included module rather
    # than on the class, so that a method defined on the entity itself wins by
    # Ruby's ordinary lookup, with no special-casing.
    #
    # Mirrors ActiveRecord's own #generated_association_methods, and must land
    # *after* it in the ancestor chain: the most recently included module sits
    # closest to the class, so that ordering is what lets this module override
    # the has_one reader (the seam RFC-0006 needs) rather than be shadowed by it.
    #
    # It holds for free. ActiveRecord's `inherited` hook calls
    # initialize_generated_modules, which creates and includes
    # GeneratedAssociationMethods at class-definition time — long before any
    # `component` line can run. So there is nothing to force here, and no order
    # of DSL calls that can invert it. That is an ActiveRecord internal, so the
    # ordering is pinned by tests ("the generated methods module" in
    # spec/dsl_spec.rb) and an upgrade that changed it would fail loudly.
    def generated_component_methods
      @generated_component_methods ||= begin
        mod = const_set(:GeneratedComponentMethods, Module.new)
        private_constant :GeneratedComponentMethods
        include mod
        mod
      end
    end

    private

    # This class and its entity superclasses, base first. Anonymous classes are
    # skipped: the registry cannot key them, so they can hold no declarations.
    def entity_ancestry
      chain = []
      klass = self

      while klass.is_a?(Class) && klass <= EcsRails::Entity
        chain.unshift(klass) if klass.name
        klass = klass.superclass
      end

      chain
    end

    def define_component_association(component_class)
      has_one component_class.model_name.singular.to_sym,
              # The name, not the class object — a reloaded component must
              # resolve to the new constant. Same rule as the registry's.
              class_name: component_class.name,
              # Every component keys on entity_id (architecture.md §2). Left to
              # itself Rails derives a has_one's foreign key from the *owner's*
              # model name, so `User has_one :email` would look for
              # emails.user_id.
              #
              # Belt-and-braces: as of Rails 7.1 `derive_foreign_key` prefers the
              # inverse's foreign key when `inverse_of:` is given, so the line
              # below would say entity_id even without this option. That is an
              # inference chain through a second option and a version-dependent
              # branch, for an invariant the gem is built on — so it is stated
              # outright rather than inferred.
              foreign_key: :entity_id,
              # The component's belongs_to is :entity, and targets the abstract
              # ApplicationEntity (RFC-0003) — too far from convention for Rails
              # to find the inverse itself. Naming it means `user.email.entity`
              # is `user`, with no second query.
              inverse_of: :entity
    end

    def validate_component_class!(component_class)
      unless component_class.is_a?(Class) && component_class < EcsRails::Component
        raise InvalidComponent,
              "#{component_class.inspect} is not an EcsRails::Component subclass"
      end

      # Not in RFC-0004, but an abstract component owns no table
      # (architecture.md §1), so its has_one could never resolve. Failing at
      # declaration time beats failing at the first read.
      return unless component_class.abstract_class?

      raise InvalidComponent,
            "#{component_class.name} is abstract and owns no table; " \
            "declare a concrete component"
    end

    # ADR-0005 is per entity, and a subclass is an entity. Redeclaring would
    # define a second has_one over the same unique entity_id row, so it is a
    # duplicate however the registry happens to be keyed. Only the inherited case
    # is checked here — the registry raises for this class's own duplicates.
    def validate_not_inherited!(component_class)
      return unless superclass.respond_to?(:component_declarations)

      clash = superclass.component_declarations.find do |declaration|
        declaration.component_class_name == component_class.name
      end
      return unless clash

      raise DuplicateComponent,
            "#{name} already declares #{component_class.name}, " \
            "inherited from #{clash.entity_class_name}"
    end

    def normalized_delegation_options(only:, except:)
      if only && except
        raise ArgumentError,
              "`only:` and `except:` are mutually exclusive; pass at most one"
      end

      return { only: method_names(only) } if only
      return { except: method_names(except) } if except

      {}
    end

    def method_names(value)
      Array(value).map do |name|
        unless name.is_a?(Symbol) || name.is_a?(String)
          raise ArgumentError, "expected a method name, got #{name.inspect}"
        end

        name.to_sym
      end
    end
  end
end
