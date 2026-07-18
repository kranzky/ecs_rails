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
  #   User.create!.email         # => the Email row, or a virtual one (RFC-0006)
  #
  # Each declaration does three things: it records itself in the registry
  # (RFC-0002), it sets up the has_one that reads the component row, and it
  # generates the lazy reader (RFC-0006) into #generated_component_methods —
  # the module RFC-0005's delegated methods also land in.
  module DSL
    # Declares that this entity is composed from `component_class`.
    #
    # Defines a reader named for the component's model_name.singular, so
    # `component Email` gives `#email`.
    #
    # **The reader always returns an instance, never nil** (architecture.md §3).
    # If the entity has no row for the component, a virtual one is built with
    # every attribute at its default. That is RFC-0006's doing, layered on top of
    # this RFC through #generated_component_methods rather than woven into it —
    # see #define_component_reader.
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

      # RFC-0005 is resolved *before* anything is registered or defined, so that
      # a bad `only:`/`except:` name or a DelegationConflict leaves the class in
      # exactly the state it was in. #delegated_method_names validates the option
      # names against the component's real method set (ArgumentError on a typo);
      # #detect_delegation_conflict! raises DelegationConflict (ADR-0004) if any
      # of those names is already delegated by a sibling component.
      delegated = delegated_method_names(component_class, options)
      detect_delegation_conflict!(component_class, delegated)

      # Registered first, so that the registry's own duplicate check (RFC-0002)
      # is what stops a doubled `component` line — before any method is defined.
      declaration = EcsRails.registry.register(
        entity_class: self,
        component_class: component_class,
        options: options
      )

      define_component_association(component_class)

      # Must follow the has_one: see #generated_component_methods.
      define_component_reader(component_class)

      # RFC-0005: the delegating methods, into the same module as the reader.
      define_component_delegation(component_class, delegated)

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

    # The lazy reader (RFC-0006), generated into the seam this DSL already
    # builds: generated_component_methods sits closer to the class than
    # ActiveRecord's GeneratedAssociationMethods, so this wins, and `super`
    # reaches the has_one reader underneath. Nothing else moves.
    #
    # `super()` with explicit parens is required, not style: a method defined by
    # define_method cannot use bare `super`, because there is no static argument
    # list for it to forward.
    #
    # The reader is generated per component rather than defined once on
    # Lazy::Entity because there is nothing generic to define — each one closes
    # over its own name and its own has_one to call through to.
    def define_component_reader(component_class)
      name = component_class.model_name.singular.to_sym

      generated_component_methods.define_method(name) do
        ecs_component(name) { super() }
      end
    end

    # RFC-0005: generates one delegating method on the entity, per name in the
    # delegated set, into the same module the reader lives in.
    #
    # The methods live in generated_component_methods (an *included* module), so
    # a method defined directly on the entity class shadows them by Ruby's own
    # lookup — which is exactly ADR-0004's "a method on the entity itself wins
    # silently, no conflict". No special-casing here achieves that.
    #
    # Each generated method calls the entity's own component reader (`email`),
    # so it goes through RFC-0006's memo and reaches the one instance the save
    # cascade will later persist — the seam that makes `user.address = "x";
    # user.save!` write a single row. It does *not* rebind self or instance_exec
    # (ADR-0001): it forwards the call, so `self` inside the component method is
    # the component, never the entity.
    #
    # *args, **kwargs and &block are all forwarded untouched (RFC-0005).
    def define_component_delegation(component_class, delegated)
      reader = component_class.model_name.singular.to_sym
      mod = generated_component_methods

      delegated.each do |method_name|
        mod.define_method(method_name) do |*args, **kwargs, &block|
          public_send(reader).public_send(method_name, *args, **kwargs, &block)
        end
      end
    end

    # RFC-0005: the set of method names delegated for one component, after
    # `only:`/`except:` are applied. Also the place their names are validated —
    # RFC-0004 stored them but never checked they name anything real.
    #
    # `only:` keeps the named members; `except:` drops them. Both are attribute
    # aware: naming an attribute (`:title`) covers both its reader and its writer
    # (`:title`, `:title=`), so `except: [:title]` fully resolves a `#title`
    # conflict rather than leaving `#title=` still clashing. The RFC's own
    # resolution test — `component Group, except: [:title]` with no error —
    # requires exactly this; a literal-name filter would still raise on `#title=`.
    def delegated_method_names(component_class, options)
      full = delegable_methods(component_class)
      pairs = attribute_accessor_index(component_class, full)

      if (only = options[:only])
        validate_delegation_names!(component_class, only, full, pairs, :only)
        full & expand_delegation_names(only, pairs)
      elsif (except = options[:except])
        validate_delegation_names!(component_class, except, full, pairs, :except)
        full - expand_delegation_names(except, pairs)
      else
        full
      end
    end

    # The full delegable set for a component, before `only:`/`except:`.
    #
    # "Methods the component itself declares" is the fiddly part (RFC-0005 says
    # so), and neither obvious shape is right on its own:
    #
    #   - instance_methods(false) misses methods gained from included modules
    #     (Name#initials comes from Nameable) and misses attribute accessors.
    #   - instance_methods minus EcsRails::Component's picks up module methods,
    #     but once ActiveRecord has lazily generated a component's attribute
    #     methods it also drags in every dirty-tracking helper — address_was,
    #     address_changed?, saved_change_to_address?, and a hundred more.
    #
    # So behaviour and attributes are computed separately and unioned:
    #
    #   behaviour  = public instance methods, minus everything Component and its
    #                ancestors define, minus the AR-generated attribute module
    #                (which is where all those helpers live). What remains is the
    #                methods the component genuinely wrote — send_welcome_email,
    #                who_am_i, full_name, initials.
    #   accessors  = a reader and writer for each attribute the component owns.
    #
    # generated_attribute_methods is private ActiveRecord API. The gem already
    # depends on AR internals with tests pinning them (ADR-0008's
    # instantiate_instance_of; architecture.md open question 9), and this is the
    # same bargain: pinned by the exact-set tests in delegation_spec, so a Rails
    # upgrade that moved these methods fails loudly rather than silently widening
    # what an entity delegates.
    def delegable_methods(component_class)
      attr_module = component_class.send(:generated_attribute_methods)

      behaviour = component_class.public_instance_methods(true) -
                  EcsRails::Component.public_instance_methods(true) -
                  attr_module.instance_methods(false)

      accessors = component_class.attribute_names.flat_map do |attribute|
        [attribute.to_sym, :"#{attribute}="]
      end

      ((behaviour + accessors).uniq - never_delegated(component_class)).sort
    end

    # Identity, not state: never delegated (RFC-0005). The primary key, the
    # entity_id foreign key, and the component timestamps — with their writers —
    # plus the :entity association (already excluded via the Component subtraction
    # above, restated here so the boundary is explicit rather than incidental).
    def never_delegated(component_class)
      attributes = [component_class.primary_key, "entity_id", "created_at", "updated_at"]

      attributes.flat_map { |attribute| [attribute.to_sym, :"#{attribute}="] } +
        %i[entity entity=]
    end

    # Maps each delegable attribute to its accessor pair, so `only:`/`except:`
    # can be attribute aware. Keyed by the reader symbol; the value is whichever
    # of [reader, writer] actually survived into the delegable set.
    def attribute_accessor_index(component_class, full)
      component_class.attribute_names.each_with_object({}) do |attribute, index|
        reader = attribute.to_sym
        writer = :"#{attribute}="
        pair = [reader, writer].select { |name| full.include?(name) }
        index[reader] = pair unless pair.empty?
      end
    end

    # Expands `only:`/`except:` names to the concrete methods they name. An
    # attribute name — whether given as `:title` or `:title=` — expands to its
    # whole accessor pair; anything else is taken literally.
    def expand_delegation_names(names, pairs)
      names.flat_map do |name|
        base = name.to_s.chomp("=").to_sym
        pairs.key?(base) ? pairs[base] : [name]
      end.uniq
    end

    # RFC-0005 / RFC-0004: `only:`/`except:` names were stored but never checked.
    # A name that matches nothing the component delegates is almost certainly a
    # typo — and a silent no-op here is precisely the action-at-a-distance
    # ADR-0004 exists to stop (a mistyped `except:` fails to resolve a conflict;
    # a mistyped `only:` delegates nothing). So an unknown name raises at
    # declaration time, naming the component and the offending method.
    def validate_delegation_names!(component_class, names, full, pairs, keyword)
      names.each do |name|
        base = name.to_s.chomp("=").to_sym
        next if full.include?(name) || pairs.key?(base)

        raise ArgumentError,
              "`#{keyword}: [:#{name}]` names #{component_class.name}##{name}, " \
              "which #{component_class.name} does not delegate. Delegable methods: " \
              "#{full.map { |m| "##{m}" }.join(', ')}."
      end
    end

    # ADR-0004: two components on one entity delegating the same name is a
    # DelegationConflict, raised here at declaration time — never a silent
    # last-wins. Checked against every component already declared on this entity
    # and its ancestors (the new one is not registered yet), so the message can
    # name the sibling that got there first.
    #
    # Only component-vs-component overlaps count. An overlap with a method the
    # entity itself defines is not a conflict: that method wins by Ruby's lookup
    # (the generated module is included), which is ADR-0004's other half.
    def detect_delegation_conflict!(component_class, delegated)
      owners = {}
      component_declarations.each do |declaration|
        # A component never conflicts with itself: the same component declared
        # twice on one entity is a DuplicateComponent (ADR-0005), which the
        # registry raises on #register just after this check. Comparing it here
        # would report a spurious "#address is defined by both Email and Email".
        next if declaration.component_class_name == component_class.name

        other = declaration.component_class
        delegated_method_names(other, declaration.options).each do |name|
          owners[name] ||= other
        end
      end

      # Sort so the reader (`title`) is reported before its writer (`title=`) —
      # "title" < "title=" — giving the tidier message and except: hint.
      clash = delegated.select { |name| owners.key?(name) }.min_by(&:to_s)
      return unless clash

      raise DelegationConflict,
            delegation_conflict_message(component_class, owners[clash], clash)
    end

    # The message ADR-0004 specifies: the method, both components, the entity,
    # and the exact `except:` line that resolves it.
    def delegation_conflict_message(new_component, existing_component, method)
      attribute = method.to_s.chomp("=").to_sym
      reader = new_component.model_name.singular

      "##{method} is defined by both #{existing_component.name} and " \
        "#{new_component.name} on #{name}. " \
        "Disambiguate with `component #{new_component.name}, except: [:#{attribute}]` " \
        "or call #{model_name.singular}.#{reader}.#{attribute} directly."
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
