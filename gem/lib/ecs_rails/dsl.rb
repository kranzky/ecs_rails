# frozen_string_literal: true

module EcsRails
  # The class-level DSL that composes an entity out of components.
  #
  # Implements RFC-0004. Extended into {EcsRails::Entity}, so every entity class —
  # and every subclass of one — answers `component`.
  #
  #   class User < ApplicationEntity
  #     component Name
  #     component Email
  #     component PublishState, prefix: false
  #     component PostalAddress
  #     component PostalAddress, prefix: :business
  #   end
  #
  #   User.components            # => [Name, Email, PublishState, PostalAddress]
  #   User.create!.email         # => the Email row, or a virtual one (RFC-0006)
  #   User.new.email_address     # => delegated, prefixed with the reader (ADR-0016)
  #   User.new.state             # => delegated bare, because of `prefix: false`
  #   User.new.business_address  # => the "business" slot of PostalAddress (RFC-0014)
  #
  # Each declaration does three things: it records itself in the registry
  # (RFC-0002), it sets up the slot-scoped has_one that reads the component
  # row, and it generates the lazy reader (RFC-0006) into
  # #generated_component_methods — the module RFC-0005's delegated methods also
  # land in.
  module DSL
    # Declares that this entity is composed from `component_class`.
    #
    # Defines a reader named for the component's model_name.singular, so
    # `component Email` gives `#email`. With a slot label — `component
    # PostalAddress, prefix: :business` (RFC-0014 / ADR-0015) — the reader is
    # `#business_address`, and the same component may be declared again under
    # another label. Each `(entity, slot)` is one instance, stored in the same
    # table under a `slot` column; the singular case is slot `""`.
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
    # RFC-0005 acts on them. Both name the **component's** methods (`:title`),
    # never the prefixed entity-level name (`:group_title`).
    #
    # Delegated methods are **prefixed with the reader** by default (ADR-0016):
    # `component Email` gives `user.email_address`, `user.email_verified` and
    # `user.email_send_welcome_email`, all routed through `user.email`. The rule
    # is uniform — attributes and behaviour alike — so two components can never
    # collide on a shared attribute name, and a reader is never shadowed by a
    # delegated `belongs_to`. `prefix: false` restores bare delegation for a
    # component whose prefixed names would be redundant (`publish_state_state`).
    # A verb that reads badly prefixed is reached through the reader instead
    # (`user.email.send_welcome_email`), or renamed on the component.
    # `delegate: false` (RFC-0014) drops delegation entirely — reader only — for
    # when even the prefixed names get long (`billing_address_postal_code`).
    #
    # Any further keyword is a **per-slot option** for the component
    # (RFC-0014): `component State, prefix: :order, states: %w[pending paid]`.
    # The component must have declared it with `slot_option`; an unknown one
    # raises here. See {EcsRails::Slots::Component::ClassMethods#slot_option}.
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
    #
    # @example Composition, and the reader it generates
    #   class User < ApplicationEntity
    #     component Email
    #   end
    #
    #   User.new.email           # => #<Email> — never nil
    #
    # @example Prefixed delegation, the default (ADR-0016)
    #   component Email
    #
    #   user.email_address = "a@b.com"   # => user.email.address = "a@b.com"
    #   user.email_send_welcome_email    # => user.email.send_welcome_email
    #
    # @example Bare delegation, where the prefix would be redundant
    #   component PublishState, prefix: false
    #
    #   post.state                       # => post.publish_state.state
    #
    # @example Resolving a delegation conflict between two bare components
    #   component Group, prefix: false, except: [:title]
    #
    # @example Two slots of one component (RFC-0014)
    #   component PostalAddress                       # user.postal_address
    #   component PostalAddress, prefix: :business    # user.business_address,
    #                                                 #   user.business_address_line1
    #
    # @example Reader only, and a per-slot option
    #   component PostalAddress, prefix: :remit, delegate: false, country: "NZ"
    #
    # @param component_class [Class<EcsRails::Component>] a concrete component
    # @param only [Array<Symbol>, Symbol, nil] delegate only these methods.
    #   Attribute aware: `:title` covers `#title` and `#title=`. Names the
    #   component's methods, not the prefixed entity-level names.
    #   Mutually exclusive with `except:`.
    # @param except [Array<Symbol>, Symbol, nil] delegate everything but these.
    #   Attribute aware, as `only:` is. Mutually exclusive with `only:`.
    # @param prefix [Symbol, String, Boolean, nil] the slot label and, with it,
    #   how the reader and delegated methods are named. Omitted (or `true`): the
    #   default slot, reader `email`, delegation `email_address` (ADR-0016).
    #   `false`: the default slot with bare delegation — `address`. A Symbol
    #   (`:business`): slot `"business"`, reader `business_address`, delegation
    #   `business_address_line1` (RFC-0014). Must be a valid method-name segment.
    # @param delegate [Boolean] `false` generates the reader and predicate only,
    #   no delegated methods (RFC-0014). Meaningless with `only:`/`except:`.
    # @param slot_options [Hash{Symbol => Object}] per-slot options for the
    #   component, each declared on it with `slot_option` (RFC-0014)
    # @return [EcsRails::Registry::Declaration] the recorded declaration
    # @raise [EcsRails::InvalidComponent] if `component_class` is not a concrete
    #   {EcsRails::Component} subclass, or is abstract and so owns no table
    # @raise [EcsRails::DuplicateComponent] if this entity, or one it inherits
    #   from, already declares this component in this slot (ADR-0005 / ADR-0015)
    # @raise [EcsRails::DelegationConflict] if a delegated name is already
    #   delegated by a sibling component, or collides with a component reader,
    #   or the new reader collides with an existing reader or delegated method
    #   (ADR-0004)
    # @raise [ArgumentError] if both `only:` and `except:` are given, if either
    #   names a method the component does not delegate, if `prefix:` is not a
    #   Boolean or a valid label, if `delegate:` is not a Boolean, if a slot
    #   option is not one the component declares, or if either class is anonymous
    # @see #components
    # @see #declaration_for
    # @see EcsRails::Presence::Entity#has? the `<reader>?` predicate this generates
    def component(component_class, only: nil, except: nil, prefix: nil, delegate: true, **slot_options)
      validate_component_class!(component_class)
      slot = normalized_slot(prefix)
      options = normalized_delegation_options(only: only, except: except, prefix: prefix, delegate: delegate)
      slot_options = normalized_slot_options(component_class, slot_options)
      validate_not_inherited!(component_class, slot)

      # RFC-0005 is resolved *before* anything is registered or defined, so that
      # a bad `only:`/`except:` name or a DelegationConflict leaves the class in
      # exactly the state it was in. #delegation_map validates the option names
      # against the component's real method set (ArgumentError on a typo) and
      # applies the ADR-0016 prefix; #detect_delegation_conflict! raises
      # DelegationConflict (ADR-0004) if any resulting entity-level name is
      # already delegated by a sibling component.
      delegated = delegation_map(component_class, slot, options)
      detect_delegation_conflict!(component_class, slot, delegated)
      detect_reader_collision!(component_class, slot, delegated)

      # Registered first, so that the registry's own duplicate check (RFC-0002)
      # is what stops a doubled `component` line — before any method is defined.
      declaration = EcsRails.registry.register(
        entity_class: self,
        component_class: component_class,
        slot: slot,
        options: options,
        slot_options: slot_options
      )

      define_component_association(component_class, slot)

      # Must follow the has_one: see #generated_component_methods.
      define_component_reader(component_class, slot)

      # RFC-0005: the delegating methods, into the same module as the reader.
      define_component_delegation(component_class, slot, delegated)

      # RFC-0009: the `<reader>?` presence predicate. Generated last so it can
      # see, and defer to, any delegated method that already owns its name.
      define_component_predicate(component_class, slot)

      declaration
    end

    # Every component this entity is composed from, nearest ancestor last.
    #
    # Inherited components are included: a subclass is composed from its parents'
    # components as well as its own. A component declared under two slots
    # (RFC-0014) appears once — this answers "what types is it made of"; see
    # {#component_declarations} for the per-slot view.
    #
    # @example
    #   User.components  # => [Name, Email, Group]
    #
    # @return [Array<Class<EcsRails::Component>>] the component classes, resolved
    #   live from the registry (so a reloaded constant is picked up)
    # @see #component_declarations
    def components
      component_declarations.map(&:component_class).uniq
    end

    # The declaration of `component_class` on this entity under `prefix`, or nil.
    #
    # The lookup presence (RFC-0009), preloading (RFC-0011) and a component's
    # own {EcsRails::Slots::Component#slot_options} all resolve through, so
    # "which reader, which slot options" is answered in one place.
    #
    # @example
    #   User.declaration_for(PostalAddress)                     # the default slot
    #   User.declaration_for(PostalAddress, prefix: :business)  # the labelled one
    #   User.declaration_for(PostalAddress, prefix: :business).reader_name  # => :business_address
    #
    # @param component_class [Class<EcsRails::Component>] the component
    # @param prefix [Symbol, String, nil] the slot label; nil for the default slot
    # @return [EcsRails::Registry::Declaration, nil] ancestry included
    # @see #component_declarations
    def declaration_for(component_class, prefix: nil)
      slot = prefix.to_s
      component_declarations.find do |declaration|
        declaration.component_class_name == component_class.name && declaration.slot == slot
      end
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
    #
    # @return [Array<EcsRails::Registry::Declaration>] declarations, ancestors'
    #   first, in declaration order. Carries the slot and the `only:`/`except:`
    #   options that {#components} discards.
    # @see #components
    # @see #declaration_for
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
    #
    # @return [Module] the per-class module holding generated readers, delegated
    #   methods and presence predicates
    # @api private
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
    # over its own name, its slot, and its own has_one to call through to. The
    # slot is handed to the memo so a virtual is built with it preset
    # (RFC-0014): `user.business_address` with no row is a PostalAddress whose
    # `slot` is already `"business"`.
    def define_component_reader(component_class, slot)
      name = reader_name_for(component_class, slot)
      slot_value = slot.to_s

      generated_component_methods.define_method(name) do
        ecs_component(name, slot_value) { super() }
      end
    end

    # RFC-0005: generates one delegating method on the entity, per entry in the
    # delegation map, into the same module the reader lives in.
    #
    # The methods live in generated_component_methods (an *included* module), so
    # a method defined directly on the entity class shadows them by Ruby's own
    # lookup — which is exactly ADR-0004's "a method on the entity itself wins
    # silently, no conflict". No special-casing here achieves that.
    #
    # Each generated method calls the entity's own component reader (`email`),
    # so it goes through RFC-0006's memo and reaches the one instance the save
    # cascade will later persist — the seam that makes `user.email_address =
    # "x"; user.save!` write a single row. It does *not* rebind self or
    # instance_exec (ADR-0001): it forwards the call, so `self` inside the
    # component method is the component, never the entity.
    #
    # The entity-level name (`email_address`) and the component method it
    # forwards to (`address`) differ under ADR-0016's default prefix; the map
    # carries both, so this is the only place that needs to know.
    #
    # *args, **kwargs and &block are all forwarded untouched (RFC-0005).
    def define_component_delegation(component_class, slot, delegated)
      reader = reader_name_for(component_class, slot)
      mod = generated_component_methods

      delegated.each do |entity_method, component_method|
        mod.define_method(entity_method) do |*args, **kwargs, &block|
          public_send(reader).public_send(component_method, *args, **kwargs, &block)
        end
      end
    end

    # RFC-0009: the presence predicate `entity.<reader>?`, generated per
    # component into the same module as the reader and delegation. It is exactly
    # `has?(ThatComponent)` — `user.moderator?`, `user.email?` — the per-component
    # sugar over EcsRails::Presence::Entity#has?.
    #
    # Generated for every component, not just markers (ADR-0009): "does a row
    # exist?" is a question every component answers.
    #
    # Collision: the predicate name is `<reader>?`, and a component *could*, in
    # principle, delegate a method of that exact name (a `<reader>?` in its own
    # delegable set). That is the reader-collision situation the same way the
    # reader itself is (ADR-0009), but far rarer, and a delegated method is the
    # developer's explicit choice — so rather than raise, we simply do not
    # clobber it: if the module already defines this name (from this component's
    # delegation, generated just above, or a sibling's), the delegated method
    # wins and no predicate is generated. The common case has no such method and
    # the predicate is defined normally.
    #
    # Per slot (RFC-0014): `user.business_address?` asks `has?(PostalAddress,
    # prefix: :business)`.
    def define_component_predicate(component_class, slot)
      predicate = :"#{reader_name_for(component_class, slot)}?"
      mod = generated_component_methods
      return if mod.instance_methods(false).include?(predicate)

      # Closed over the class so a reloaded constant still resolves through
      # #has?'s declared-set check, same as the reader closes over its name.
      component = component_class
      prefix = slot.to_s.empty? ? nil : slot.to_sym
      mod.define_method(predicate) { has?(component, prefix: prefix) }
    end

    # ADR-0016: the names an entity answers for one component, each mapped to
    # the component method it forwards to. Keys are entity-level
    # (`email_address`), values component-level (`address`).
    #
    # By default every name is prefixed with the component's reader, so the one
    # rule is `#{reader}_#{method}` — the same shape RFC-0014's labelled slots
    # use, which is what makes the two cases one rule. `prefix: false` makes
    # key and value identical (bare delegation). The prefix is applied to the
    # whole delegated set, behaviour included: `email_send_welcome_email` is
    # ugly but unambiguous, and the reader (`user.email.send_welcome_email`) is
    # always there for a verb that reads badly prefixed. An attributes-only rule
    # would need a heuristic for what counts as an attribute and would reopen the
    # verb collisions ADR-0016 exists to close.
    #
    # A labelled slot (RFC-0014) prefixes with *its* reader — `business_address_line1`
    # — which is what keeps two slots of one component apart. `delegate: false`
    # is the empty map: reader and predicate only.
    #
    # Conflict detection, reader collision and method generation all work on
    # this map, so "what does the entity answer" is computed in one place.
    def delegation_map(component_class, slot, options)
      return {} if options[:delegate] == false

      names = delegated_method_names(component_class, options)
      return names.to_h { |name| [name, name] } if options[:prefix] == false

      reader = reader_name_for(component_class, slot)
      names.to_h { |name| [:"#{reader}_#{name}", name] }
    end

    # The same map for a declaration already in the registry.
    def delegation_map_for(declaration)
      delegation_map(declaration.component_class, declaration.slot, declaration.options)
    end

    # RFC-0005: the set of the component's own method names delegated for one
    # component, after `only:`/`except:` are applied — before ADR-0016's prefix,
    # which #delegation_map adds. Also the place the option names are validated —
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
    # entity_id foreign key, the slot (RFC-0014: which of an entity's rows this
    # is, never something about it), and the component timestamps — with their
    # writers — plus the :entity association (already excluded via the Component
    # subtraction above, restated here so the boundary is explicit rather than
    # incidental).
    def never_delegated(component_class)
      attributes = [component_class.primary_key, "entity_id", "slot", "created_at", "updated_at"]

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
    # Compared on the *entity-level* names (ADR-0016), so two components that
    # share an attribute (`Name#title`, `Group#title`) no longer clash — they
    # delegate `name_title` and `group_title`. A clash now needs both to be
    # bare (`prefix: false`), or a prefixed name to spell out another's
    # (`EmailAddress#verified` vs `Email#address_verified`). The raise stays as
    # the backstop ADR-0004 promised.
    #
    # Only component-vs-component overlaps count. An overlap with a method the
    # entity itself defines is not a conflict: that method wins by Ruby's lookup
    # (the generated module is included), which is ADR-0004's other half.
    def detect_delegation_conflict!(component_class, slot, delegated)
      owners = {}
      component_declarations.each do |declaration|
        # A component never conflicts with itself: the same component declared
        # twice in one slot on one entity is a DuplicateComponent (ADR-0005),
        # which the registry raises on #register just after this check.
        # Comparing it here would report a spurious "#address is defined by both
        # Email and Email". The same component in *another* slot is a genuine
        # sibling (RFC-0014) and is compared like any other.
        next if declaration.component_class_name == component_class.name && declaration.slot == slot

        other = declaration.component_class
        delegation_map_for(declaration).each_key do |name|
          owners[name] ||= other
        end
      end

      # Sort so the reader (`title`) is reported before its writer (`title=`) —
      # "title" < "title=" — giving the tidier message and except: hint.
      clash = delegated.keys.select { |name| owners.key?(name) }.min_by(&:to_s)
      return unless clash

      raise DelegationConflict,
            delegation_conflict_message(component_class, slot, owners[clash], clash, delegated[clash])
    end

    # A component reader (`post.author`) is structural — it is how you reach the
    # component at all — so its name is reserved. A delegated method that would
    # take the same name must not silently overwrite the reader: it did, and
    # because the generated method then called the reader, `post.author` recursed
    # into itself (SystemStackError). This is genuine ambiguity of exactly the
    # kind ADR-0004 raises on: does `post.author` mean the Author *component*, or
    # the User that `belongs_to :author` inside it points at? Surface it at
    # declaration time and make the developer choose.
    #
    # Fires when a delegated name equals any component reader on the entity — the
    # new component's own reader (the `Author` with `belongs_to :author` case) or
    # a sibling's. The reverse — a sibling's delegated method colliding with the
    # new reader — is the same names from the other side, and
    # #detect_delegation_conflict! on the earlier declaration already covers it.
    #
    # Under ADR-0016's default prefix this can only fire for a `prefix: false`
    # component (a prefixed name always starts with its own reader plus an
    # underscore, so it can never *equal* a reader) — or when a prefixed name
    # happens to spell a sibling's reader. Checked on the entity-level names.
    #
    # The other direction is checked too (RFC-0014): the NEW reader must not be
    # a name the entity already answers — a sibling's reader, or a sibling's
    # delegated method. Slots make this likelier: `component Address, prefix:
    # :business` wants `business_address`, which a `BusinessAddress` component
    # or an `Email#business_address` delegation could already own. The same
    # (component, slot) twice is *not* caught here — that is the registry's
    # DuplicateComponent, raised a moment later.
    def detect_reader_collision!(component_class, slot, delegated)
      reader = reader_name_for(component_class, slot)
      siblings = component_declarations.reject do |d|
        d.component_class_name == component_class.name && d.slot == slot
      end
      readers = siblings.map(&:reader_name)

      clash = delegated.keys.find { |name| readers.include?(name) || name == reader }
      if clash
        raise DelegationConflict,
              reader_collision_message(component_class, slot, clash, delegated[clash])
      end

      taken = readers + siblings.flat_map { |d| delegation_map_for(d).keys }
      return unless taken.include?(reader)

      raise DelegationConflict,
            "##{reader} on #{name} is the reader `component #{component_class.name}"             "#{slot.empty? ? '' : ", prefix: :#{slot}"}` would generate, but #{name} "             "already answers ##{reader} — another component's reader or delegated "             "method. Choose a different prefix, or exclude the delegated method."
    end

    # The reader for a component under a slot — `email`, or `business_address`
    # for `component PostalAddress, prefix: :business`. Derived by the component
    # so the declaration, presence, preloading and the component's own
    # destroy-reset all agree (EcsRails::Slots::Component).
    def reader_name_for(component_class, slot = "")
      component_class.ecs_reader_name(slot)
    end

    # Names the collision and the three ways out: keep the default prefix,
    # rename the offending method (usually a relationship component's
    # `belongs_to`), or exclude it. `except:` takes the component's own method
    # name, which is why the map's value is passed alongside the clashing key.
    def reader_collision_message(component_class, slot, method, component_method)
      "##{method} on #{name} is both a component reader and a method delegated " \
        "from #{component_class.name}. A reader name is reserved. Drop " \
        "`prefix: false` so the method is delegated as " \
        "#{reader_name_for(component_class, slot)}_#{component_method}, rename the " \
        "method — for a relationship component, name the association for its " \
        "target (e.g. `belongs_to :user`) rather than the component — or exclude " \
        "it with `component #{component_class.name}, except: [:#{component_method.to_s.chomp("=")}]`."
    end

    # The message ADR-0004 specifies: the method, both components, the entity,
    # and the exact `except:` line that resolves it. The `except:` hint names
    # the component's own method (`:title`), not the entity-level name.
    def delegation_conflict_message(new_component, slot, existing_component, method, component_method)
      attribute = component_method.to_s.chomp("=").to_sym
      reader = reader_name_for(new_component, slot)

      "##{method} is defined by both #{existing_component.name} and " \
        "#{new_component.name} on #{name}. " \
        "Disambiguate with `component #{new_component.name}, except: [:#{attribute}]` " \
        "or call #{model_name.singular}.#{reader}.#{attribute} directly."
    end

    # The has_one is **slot-scoped** (RFC-0014 / ADR-0015): `where(slot:
    # "business")` for a labelled slot, and `where(slot: "")` for the default
    # one. Always, not only when a component is declared twice — with two slots
    # of `PostalAddress` on one entity, an unscoped default has_one would return
    # whichever row the database offered first. Uniform scoping is what makes
    # singular a genuine special case of one code path (ADR-0015), at the cost
    # of one `AND slot = ''` per component read. ActiveRecord's preloader
    # applies the same scope, so `includes_components` stays correct.
    def define_component_association(component_class, slot)
      slot_value = slot.to_s

      has_one reader_name_for(component_class, slot),
              -> { where(slot: slot_value) },
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
    # define a second has_one over the same unique (entity_id, slot) row, so it
    # is a duplicate however the registry happens to be keyed. Only the
    # inherited case is checked here — the registry raises for this class's own
    # duplicates. The same component under a *different* slot is not a duplicate
    # (RFC-0014).
    def validate_not_inherited!(component_class, slot)
      return unless superclass.respond_to?(:component_declarations)

      clash = superclass.component_declarations.find do |declaration|
        declaration.component_class_name == component_class.name && declaration.slot == slot
      end
      return unless clash

      where = slot.empty? ? "" : " (prefix: :#{slot})"
      raise DuplicateComponent,
            "#{name} already declares #{component_class.name}#{where}, " \
            "inherited from #{clash.entity_class_name}"
    end

    # The options the registry records for a declaration: `only:`/`except:` as
    # normalised symbol arrays, `prefix: false` when bare delegation was asked
    # for, and `delegate: false` when none was. The defaults are *not* recorded
    # — `{}` still means "all of it, prefixed" — so a plain `component Email`
    # declaration compares equal before and after ADR-0016, and conflict
    # detection re-derives the same map from the same options. The slot itself
    # is not an option: it is the declaration's identity, recorded alongside.
    def normalized_delegation_options(only:, except:, prefix:, delegate:)
      if only && except
        raise ArgumentError,
              "`only:` and `except:` are mutually exclusive; pass at most one"
      end

      unless delegate == true || delegate == false
        raise ArgumentError, "`delegate:` expects true or false; got #{delegate.inspect}"
      end

      if !delegate && (only || except)
        raise ArgumentError,
              "`delegate: false` generates no delegated methods, so `only:`/`except:` " \
              "have nothing to select from; drop one or the other"
      end

      options = {}
      options[:only] = method_names(only) if only
      options[:except] = method_names(except) if except
      options[:prefix] = false if prefix == false
      options[:delegate] = false unless delegate
      options
    end

    # The slot a `prefix:` names (RFC-0014 / ADR-0015). `nil`, `true` and
    # `false` are all the default slot, `""` — ADR-0016's Booleans say how the
    # default slot delegates, not which slot it is. A Symbol or String is a
    # label, stored as its string form; it must be a valid method-name segment,
    # because it becomes the head of the reader (`business_address`) and of
    # every delegated method. `""` is rejected explicitly: it would silently
    # mean the default slot while reading as a label.
    def normalized_slot(prefix)
      case prefix
      when nil, true, false then ""
      when Symbol, String
        label = prefix.to_s
        return label if label.match?(/\A[a-z_][a-z0-9_]*\z/)

        raise ArgumentError,
              "`prefix: #{prefix.inspect}` is not a valid slot label; use a " \
              "lowercase method-name segment such as :business or :mobile"
      else
        raise ArgumentError,
              "`prefix:` expects true (the default: delegated methods are named " \
              "#{model_name.singular}.<reader>_<method>), false (bare <method>), " \
              "or a Symbol slot label (`prefix: :business`, RFC-0014); got #{prefix.inspect}"
      end
    end

    # RFC-0014 slot configuration: every extra keyword on `component` must be an
    # option the component declared with `slot_option`. Fail-loud (ADR-0004): a
    # mistyped option that silently configured nothing would be exactly the
    # action-at-a-distance the rest of the DSL refuses.
    def normalized_slot_options(component_class, slot_options)
      accepted = component_class.slot_option_names
      unknown = slot_options.keys.map(&:to_sym) - accepted
      return slot_options.transform_keys(&:to_sym) if unknown.empty?

      known = accepted.empty? ? "none" : accepted.map { |k| ":#{k}" }.join(", ")
      raise ArgumentError,
            "#{component_class.name} does not accept the slot option#{'s' if unknown.size > 1} " \
            "#{unknown.map { |k| ":#{k}" }.join(', ')}. Declared slot options: #{known}. " \
            "Declare one with `slot_option :#{unknown.first}` on #{component_class.name}."
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
