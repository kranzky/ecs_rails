# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0004: the `component` DSL.
#
# Two deviations from the RFC as written are pinned here deliberately. Both are
# argued in full in the file comments below, and both are places where the RFC
# contradicts either architecture.md or its own dependency graph:
#
#   A. The reader returns nil when no row exists. RFC-0004 says it "returns the
#      component instance, materialising it lazily (RFC-0006)" — but RFC-0006 is
#      a *sibling* of RFC-0005 on top of RFC-0004, so RFC-0004 cannot depend on
#      it. See "the reader" below.
#   B. No `dependent: :destroy`. RFC-0004 asks for it; architecture.md §3 says
#      cascade is the database's job. See "destruction" below.
#
# Throwaway entity classes are stub_const'd rather than declared at file scope:
# the registry keys by class name (RFC-0002), so an anonymous class cannot
# declare components at all, and a file-scope class would leak declarations into
# every other example.
RSpec.describe "the component DSL" do
  subject(:registry) { EcsRails.registry }

  # The registry is a process-wide singleton, so every example must start clean —
  # the same convention registry_spec.rb uses.
  #
  # Start each example with an empty registry so this file's throwaway classes
  # are the only declarations. This clears the models.rb baseline for User and
  # Post too, but spec_helper's global after-hook restores it, so the clear
  # cannot leak into another file.
  before { registry.clear! }

  # A named, concrete entity class to declare components on. Entity classes need
  # no table of their own — every entity shares `entities` (ADR-0002) — so this
  # costs nothing but a constant.
  def entity_class(name = "Thing", parent = ApplicationEntity)
    stub_const(name, Class.new(parent))
  end

  # Statements issued while the block runs. Used to prove the *absence* of
  # queries, which is the only way to tell some of these designs apart.
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- registration ----------------------------------------------------------

  describe "registration" do
    it "registers the declaration with the registry" do
      entity_class.component Email

      expect(registry.components_for(Thing).map(&:component_class)).to eq [Email]
    end

    it "records declarations in declaration order" do
      thing = entity_class
      thing.component Name
      thing.component Email

      expect(registry.components_for(Thing).map(&:component_class)).to eq [Name, Email]
    end

    it "returns the declaration" do
      declaration = entity_class.component Email

      expect(declaration).to be_a EcsRails::Registry::Declaration
      expect(declaration.component_class).to eq Email
    end

    it "answers the reverse question through the registry" do
      entity_class("Thing").component Email
      entity_class("Other").component Email

      expect(registry.entities_for(Email)).to contain_exactly(Thing, Other)
    end
  end

  # --- the reader ------------------------------------------------------------
  #
  # DEFECT A. RFC-0004 says the reader "returns the component instance,
  # materialising it lazily (RFC-0006)", and its own example test asserts
  # `User.create!.email` is an Email. That test cannot pass in RFC-0004: a freshly
  # created entity has no component rows (architecture.md §3), so a plain has_one
  # reader returns nil, and making it return an instance *is* RFC-0006.
  #
  # RFC-0006 is a sibling of RFC-0005 on top of RFC-0004, not a dependency of it,
  # so RFC-0004 must stand alone. It therefore ships the plain has_one reader, and
  # the two RFC-0004 tests that assert an instance are RFC-0006's tests, filed
  # under the wrong RFC.
  #
  # The seam RFC-0006 slots into is #generated_component_methods: a module the DSL
  # includes into the entity class *after* ActiveRecord's own
  # generated_association_methods, so it sits closer to the class and its methods
  # win. RFC-0006 defines the reader there and calls `super` to reach the has_one
  # reader underneath. Nothing else about RFC-0004 has to move. The ancestry
  # ordering that makes that work is pinned under "the generated methods module".
  describe "the reader" do
    it "defines a reader named after the component's model_name.singular" do
      entity_class.component Email

      expect(Thing.new).to respond_to Email.model_name.singular
    end

    it "returns the component row when one exists" do
      user = User.create!
      email = Email.create!(entity: user, address: "a@b.com")

      expect(user.email).to eq email
    end

    # DEFECT A is closed: RFC-0006 has landed, and the example that pinned the
    # interim nil ("returns nil when no row exists — until RFC-0006 makes it
    # lazy") is deleted rather than adjusted. Its replacement is
    # spec/lazy_spec.rb's "returns a virtual component when no row exists",
    # which asserts the inverse. The gem meets architecture.md §3 again.

    # RFC-0004: only:/except: restrict delegation (RFC-0005), never the reader.
    it "keeps the reader even when methods are excluded" do
      user = User.create!
      group = Group.create!(entity: user, title: "Ops")

      expect(user.group).to eq group
    end

    it "reads a component on a sub-subclass of the declaring entity" do
      manager = entity_class("Manager", User).create!
      email = Email.create!(entity: manager, address: "a@b.com")

      expect(manager.email).to eq email
    end
  end

  # --- the underlying has_one ------------------------------------------------

  describe "the underlying has_one" do
    it "sets up a has_one against the component class" do
      entity_class.component Email
      reflection = Thing.reflect_on_association(:email)

      expect(reflection.macro).to eq :has_one
      expect(reflection.klass).to eq Email
    end

    # The trap. Left to itself Rails derives a has_one's foreign key from the
    # *owner's* model name, so `User has_one :email` looks for emails.user_id.
    # Every component keys on entity_id (architecture.md §2).
    #
    # Note this pins the contract, not the mechanism: two things currently
    # satisfy it, since Rails >= 7.1 also derives the foreign key from
    # `inverse_of:` when it is given. Deleting `foreign_key: :entity_id` from the
    # DSL keeps this example green. That is deliberate belt-and-braces, argued at
    # the option itself — the contract is what matters and it is what is asserted.
    it "keys on entity_id, not on the entity's own model name" do
      expect(User.reflect_on_association(:email).foreign_key).to eq "entity_id"
    end

    # ...and the trap really is a trap: this is what Rails does unaided.
    it "would key on the entity's model name if the DSL declared nothing" do
      thing = entity_class
      thing.has_one :email, class_name: "Email"

      expect(thing.reflect_on_association(:email).foreign_key).to eq "thing_id"
    end

    it "queries emails by entity_id" do
      expect(User.new.association(:email).scope.to_sql).to include "entity_id"
    end

    it "keys on entity_id for a component declared on a sub-subclass" do
      entity_class("Parent").component Email
      entity_class("Child", Parent).component Avatar

      expect(Child.reflect_on_association(:avatar).foreign_key).to eq "entity_id"
    end

    it "keys on entity_id for a reflection inherited by a sub-subclass" do
      expect(entity_class("Manager", User).reflect_on_association(:email).foreign_key)
        .to eq "entity_id"
    end

    # Reload safety, same rule as the registry's (RFC-0002): hold the name, not
    # the class object, so a reloaded component resolves to the new constant.
    it "names the component class rather than holding the class object" do
      entity_class.component Email

      expect(Thing.reflect_on_association(:email).options[:class_name]).to eq "Email"
    end

    # The component's belongs_to targets the abstract ApplicationEntity
    # (RFC-0003), not User. Verify the pair actually composes.
    it "wires inverse_of to the component's :entity association" do
      expect(User.reflect_on_association(:email).options[:inverse_of]).to eq :entity
    end

    it "hands the component back the very same entity object" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      fresh = User.find(user.id)

      expect(fresh.email.entity).to equal fresh
    end

    it "issues no query to walk back to the entity" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      email = User.find(user.id).email

      expect(capture_sql { email.entity }).to be_empty
    end

    it "resolves that entity as its real subclass, not ApplicationEntity" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")

      expect(User.find(user.id).email.entity).to be_a User
    end
  end

  # --- destruction -----------------------------------------------------------
  #
  # DEFECT B. RFC-0004 asks for `dependent: :destroy` on the has_one. It is not
  # applied, for three reasons:
  #
  #   1. architecture.md §3 is the binding spec and says entity.destroy cascades
  #      "(DB-level ON DELETE CASCADE)". Every component table already carries an
  #      ON DELETE CASCADE FK to entities(id) (§2). The RFC contradicts it.
  #   2. Two layers doing one job means the AR layer masks the DB layer. Drop the
  #      FK and every test still passes — the invariant stops being tested.
  #   3. dependent: :destroy costs a SELECT and a DELETE per declared component
  #      on every entity.destroy. The cascade costs nothing.
  #
  # The real cost is that a component's own destroy callbacks (dependent
  # associations, attached files) do not run on entity.destroy. That is a genuine
  # gap and belongs in an ADR, not in a has_one option smuggled in via an RFC
  # that contradicts the architecture. RFC-0006 already specifies an explicit
  # component.destroy for the case where callbacks must run.
  describe "destruction" do
    it "declares no dependent: option" do
      expect(User.reflect_on_association(:email).options).not_to include(:dependent)
    end

    it "still removes component rows when the entity is destroyed" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")

      expect { user.destroy }.to change(Email, :count).by(-1)
    end

    it "removes every component row, not just the first" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      Name.create!(entity: user, first: "Ada")

      user.destroy

      expect([Email.count, Name.count]).to eq [0, 0]
    end

    # The observable difference between the two designs, and the reason to
    # prefer the database's cascade: it does not touch the component tables at
    # all. If dependent: :destroy is ever added, this fails.
    it "does not touch the component tables to do it" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")

      expect(capture_sql { user.destroy }.grep(/emails/)).to be_empty
    end
  end

  # --- only: / except: -------------------------------------------------------
  #
  # RFC-0004 only stores these; RFC-0005 acts on them. Validated here so a typo
  # fails at class-load time rather than being silently ignored until delegation
  # lands.
  describe "only: and except:" do
    it "stores only: in the registry for RFC-0005" do
      entity_class.component Email, only: [:address]

      expect(registry.components_for(Thing).first.options).to eq(only: [:address])
    end

    it "stores except: in the registry for RFC-0005" do
      entity_class.component Group, except: [:title]

      expect(registry.components_for(Thing).first.options).to eq(except: [:title])
    end

    it "stores no options when neither is given" do
      entity_class.component Email

      expect(registry.components_for(Thing).first.options).to eq({})
    end

    it "accepts a bare symbol" do
      entity_class.component Group, except: :title

      expect(registry.components_for(Thing).first.options).to eq(except: [:title])
    end

    it "normalises strings to symbols" do
      entity_class.component Group, except: ["title"]

      expect(registry.components_for(Thing).first.options).to eq(except: [:title])
    end

    # only: and except: normalise through the same path; assert both, or the
    # branch that is not asserted quietly stops normalising.
    it "normalises only: the same way" do
      entity_class.component Email, only: ["address", :verified]

      expect(registry.components_for(Thing).first.options).to eq(only: %i[address verified])
    end

    it "accepts a bare symbol for only: too" do
      entity_class.component Email, only: :address

      expect(registry.components_for(Thing).first.options).to eq(only: [:address])
    end

    it "rejects a bad method name in only: as well as except:" do
      thing = entity_class

      expect { thing.component Email, only: [Object.new] }
        .to raise_error(ArgumentError, /method name/)
    end

    it "rejects only: and except: together" do
      thing = entity_class

      expect { thing.component Email, only: [:a], except: [:b] }
        .to raise_error(ArgumentError, /mutually exclusive/)
    end

    it "rejects a method name that is not a symbol or string" do
      thing = entity_class

      expect { thing.component Email, except: [Object.new] }
        .to raise_error(ArgumentError, /method name/)
    end

    it "registers nothing when the options are rejected" do
      thing = entity_class
      begin
        thing.component Email, only: [:a], except: [:b]
      rescue ArgumentError
        # expected
      end

      expect(registry.components_for(thing)).to eq []
    end

    it "defines no reader when the options are rejected" do
      thing = entity_class
      begin
        thing.component Email, only: [:a], except: [:b]
      rescue ArgumentError
        # expected
      end

      expect(thing.new).not_to respond_to :email
    end
  end

  # --- rejections ------------------------------------------------------------

  describe "rejections" do
    it "rejects a non-component" do
      thing = entity_class

      expect { thing.component String }.to raise_error(EcsRails::InvalidComponent, /String/)
    end

    it "rejects something that is not a class at all" do
      thing = entity_class

      expect { thing.component "Email" }.to raise_error(EcsRails::InvalidComponent)
    end

    it "rejects an entity class dressed up as a component" do
      thing = entity_class

      expect { thing.component Post }.to raise_error(EcsRails::InvalidComponent)
    end

    # Not in RFC-0004, but an abstract component owns no table (architecture.md
    # §1), so the has_one it would generate could never resolve. Fail at
    # declaration time rather than at the first read.
    it "rejects an abstract component" do
      thing = entity_class

      expect { thing.component ApplicationComponent }
        .to raise_error(EcsRails::InvalidComponent, /abstract/)
    end

    it "rejects the same component declared twice" do
      thing = entity_class
      thing.component Email

      expect { thing.component Email }
        .to raise_error(EcsRails::DuplicateComponent, /Thing.*Email/)
    end

    # The registry keys by class name so entries survive reloading (RFC-0002).
    # An anonymous class has no name, so it cannot declare components — which is
    # why every entity class in this file is stub_const'd.
    it "rejects an anonymous entity class" do
      expect { Class.new(ApplicationEntity) { component Email } }
        .to raise_error(ArgumentError, /anonymous/)
    end

    it "rejects an anonymous component class" do
      thing = entity_class

      expect { thing.component Class.new(ApplicationComponent) }
        .to raise_error(ArgumentError, /anonymous/)
    end
  end

  # --- inheritance -----------------------------------------------------------
  #
  # RFC-0004: "Subclasses inherit their parent's declarations."
  #
  # Decision: the registry is not touched. It keeps exactly what each class
  # declared, keyed by that class's own name — RFC-0002's contract, unchanged —
  # and the DSL walks the superclass chain on read. Its own example test
  # (`registry.components_for(Moderator)` includes the parent's) would require the
  # registry to *copy* declarations down into every subclass on `inherited`, which
  # is worse on three counts: it doubles entries for entities_for, so RFC-0008's
  # generator would see one component table declared N times; it misses anything
  # the parent declares after the subclass is defined; and it makes a copy of a
  # class-name-keyed store, which is the exact stale-data shape RFC-0002 exists to
  # avoid. Walking on read has none of those failure modes.
  #
  # So `registry.components_for(Admin)` returns only Admin's own, and
  # `Admin.components` is the question a caller actually means.
  describe "inheritance" do
    it "walks the superclass chain for declarations" do
      entity_class("Parent").component Email
      entity_class("Child", Parent)

      expect(Child.components).to eq [Email]
    end

    it "inherits the reader" do
      entity_class("Parent").component Email
      entity_class("Child", Parent)

      child = Child.create!
      email = Email.create!(entity: child, address: "a@b.com")

      expect(child.email).to eq email
    end

    it "lists the parent's declarations before its own" do
      entity_class("Parent").component Email
      entity_class("Child", Parent).component Avatar

      expect(Child.components).to eq [Email, Avatar]
    end

    it "reaches a grandparent" do
      entity_class("Parent").component Email
      entity_class("Child", Parent).component Avatar
      entity_class("Grandchild", Child).component Name

      expect(Grandchild.components).to eq [Email, Avatar, Name]
    end

    it "does not leak a subclass's declarations up to its parent" do
      entity_class("Parent").component Email
      entity_class("Child", Parent).component Avatar

      expect(Parent.components).to eq [Email]
    end

    # The consequence of walking rather than copying, asserted directly so the
    # decision is visible rather than inferred.
    it "leaves the registry holding only what each class itself declared" do
      entity_class("Parent").component Email
      entity_class("Child", Parent)

      expect(registry.components_for(Child)).to eq []
      expect(registry.components_for(Parent).map(&:component_class)).to eq [Email]
    end

    # ADR-0005 is per *entity*, and an Admin is an entity. Redeclaring would
    # define a second has_one over the same unique entity_id row, so it is a
    # duplicate however the registry happens to be keyed.
    it "rejects redeclaring a component the superclass already declares" do
      entity_class("Parent").component Email
      child = entity_class("Child", Parent)

      expect { child.component Email }
        .to raise_error(EcsRails::DuplicateComponent, /Child.*Email.*Parent/)
    end

    it "carries the parent's options down" do
      entity_class("Parent").component Group, except: [:title]
      entity_class("Child", Parent)

      expect(Child.component_declarations.map(&:options)).to eq [{ except: [:title] }]
    end

    it "reports no components for an entity that declares none" do
      expect(entity_class.components).to eq []
    end
  end

  # --- the generated methods module ------------------------------------------
  #
  # ADR-0004 requires generated methods to live in a module included in the
  # entity class, so that a method defined on the entity itself wins by Ruby's
  # own lookup. This is the anchor for that, and the seam RFC-0006 overrides the
  # reader in. It is empty in RFC-0004 — but the ancestry ordering it depends on
  # is subtle enough to be worth pinning now rather than discovering in RFC-0006.
  describe "the generated methods module" do
    it "is created when the first component is declared" do
      entity_class.component Email

      expect(Thing.generated_component_methods).to be_a Module
    end

    it "is included in the entity class" do
      entity_class.component Email

      expect(Thing.ancestors).to include Thing.generated_component_methods
    end

    it "is named, so a generated method's owner is readable in a backtrace" do
      entity_class.component Email

      expect(Thing.generated_component_methods.name).to eq "Thing::GeneratedComponentMethods"
    end

    # The load-bearing bit, and the reason this module is built in RFC-0004 at
    # all. Ours must sit closer to the class than ActiveRecord's association
    # module, or RFC-0006's reader override is silently unreachable and
    # RFC-0005's delegated methods lose to the has_one reader.
    #
    # It holds because AR's `inherited` hook includes GeneratedAssociationMethods
    # at class-definition time, so ours is always included later. That is an AR
    # internal, which is exactly why it is asserted here rather than assumed.
    it "sits closer to the class than ActiveRecord's association module" do
      entity_class.component Email
      ancestors = Thing.ancestors

      expect(ancestors.index(Thing.generated_component_methods))
        .to be < ancestors.index(Thing.generated_association_methods)
    end

    # ...and stays that way when the module is asked for *first*, which is how
    # RFC-0005 or RFC-0006 will reach it. Nothing in the DSL forces the order:
    # AR has already included its module by the time any entity class exists.
    it "sits closer to the class even when asked for before any association" do
      thing = entity_class
      thing.generated_component_methods
      thing.component Email
      ancestors = thing.ancestors

      expect(ancestors.index(thing.generated_component_methods))
        .to be < ancestors.index(thing.generated_association_methods)
    end

    it "can therefore override the has_one reader" do
      entity_class.component Email
      Thing.generated_component_methods.define_method(:email) { :overridden }

      expect(Thing.new.email).to eq :overridden
    end

    it "still lets a method defined on the entity itself win (ADR-0004)" do
      thing = entity_class
      thing.component Email
      thing.generated_component_methods.define_method(:email) { :from_the_module }
      thing.define_method(:email) { :from_the_entity }

      expect(thing.new.email).to eq :from_the_entity
    end

    it "gives a subclass its own module, ahead of its parent's" do
      entity_class("Parent").component Email
      entity_class("Child", Parent).component Avatar
      ancestors = Child.ancestors

      expect(Child.generated_component_methods).not_to equal Parent.generated_component_methods
      expect(ancestors.index(Child.generated_component_methods))
        .to be < ancestors.index(Parent.generated_component_methods)
    end

    it "reuses one module across several declarations on one class" do
      thing = entity_class
      thing.component Email
      mod = thing.generated_component_methods
      thing.component Name

      expect(thing.generated_component_methods).to equal mod
    end
  end

  # --- reload safety ---------------------------------------------------------
  #
  # In development Rails does not mutate a reloaded class in place: it drops the
  # constant and autoloads a brand-new Class object under the same name. The
  # Railtie clears the registry on to_prepare, so every declaration is made
  # again, on a new class, against an empty registry.
  describe "surviving a Rails development-mode class reload" do
    def reload!
      registry.clear!
      stub_const("Reloadable", Class.new(ApplicationEntity))
    end

    it "redeclares without raising DuplicateComponent" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).component Email
      reloaded = reload!

      expect { reloaded.component Email }.not_to raise_error
    end

    it "does not double-register" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).component Email
      reload!.component Email

      expect(registry.components_for(Reloadable).size).to eq 1
    end

    it "registers against the new class object" do
      original = stub_const("Reloadable", Class.new(ApplicationEntity))
      original.component Email
      reloaded = reload!
      reloaded.component Email

      expect(reloaded).not_to equal original
      expect(registry.entities_for(Email).first).to equal reloaded
    end

    it "gives the new class a working reader" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).component Email
      reloaded = reload!
      reloaded.component Email

      entity = reloaded.create!
      email = Email.create!(entity: entity, address: "a@b.com")

      expect(entity.email).to eq email
    end
  end

  # --- the host app's own models ---------------------------------------------
  #
  # spec/support/models.rb declares components the way a host app would. These
  # assert the result, not the registry, precisely because the registry is a
  # singleton that any spec may clear.
  describe "an entity composed the way a host app composes one" do
    it "reads every declared component" do
      user = User.create!

      expect(user).to respond_to(:name, :email, :group)
    end

    it "shares a component type between two entity classes" do
      expect([User.new, Post.new]).to all(respond_to(:name))
    end

    it "does not define a reader for a component it did not declare" do
      expect(User.new).not_to respond_to :avatar
    end
  end
end
