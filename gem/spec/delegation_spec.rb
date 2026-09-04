# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0005: method delegation from an entity to its components, as
# amended by ADR-0016: delegated names are prefixed with the component's reader.
#
# This is where the proposal's headline sugar becomes real:
#
#   user.email_address = "a@b.com"    # => user.email.address = "a@b.com"
#   user.email_send_welcome_email     # => user.email.send_welcome_email
#
# The one rule is `#{reader}_#{method}`. It applies uniformly — attributes and
# behaviour alike — so two components can never collide on a shared attribute,
# and `prefix: false` buys the bare name back where the prefix is redundant.
#
# The governing rule for what is left of collisions is ADR-0004: two components
# exposing the same *entity-level* name is a DelegationConflict raised at
# declaration time, never a silent last-wins.
#
# Throwaway entity classes are stub_const'd, never anonymous: the registry keys
# by class name (RFC-0002 / RFC-0004), so an anonymous entity cannot declare
# components at all. This is the tax the RFC's Notes call out.
RSpec.describe "method delegation" do
  # Start each example with an empty registry so the throwaway classes below are
  # the only declarations. spec_helper's global after-hook restores the
  # models.rb baseline once we're done, so this clear cannot leak to another
  # file — that seal is central now, not this file's responsibility.
  before { EcsRails.registry.clear! }

  # Statements issued while the block runs. Same helper as the sibling specs;
  # used to prove the money path issues exactly one INSERT.
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

  # --- the RFC's own example tests -------------------------------------------
  #
  # Copied from the RFC, renamed for ADR-0016. These are the contract. `user`
  # here is the host app's User (spec/support/models.rb), except where a test
  # needs a bespoke entity.
  describe "the RFC's contract" do
    let(:user) { User.create! }

    it "delegates a component method" do
      expect(user.email_send_welcome_email).to eq :sent
    end

    it "binds self to the component, not the entity" do
      expect(user.email_who_am_i).to be_an Email
    end

    it "delegates attribute writers" do
      user.email_address = "a@b.com"

      expect(user.email.address).to eq "a@b.com"
    end

    it "raises on a conflict at declaration time" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name, prefix: false

      expect { Clash.component Group, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /#title.*Name.*Group/)
    end

    it "lets except: resolve a conflict" do
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name, prefix: false
      Resolved.component Group, prefix: false, except: [:title]

      expect(Resolved.new.title).to eq "from Name"
    end

    it "prefers a method defined on the entity itself" do
      stub_const("Winner", Class.new(ApplicationEntity) do
        def email_address
          "entity wins"
        end
      end)
      Winner.component Email

      expect(Winner.create!.email_address).to eq "entity wins"
    end

    it "does not delegate ActiveRecord plumbing" do
      expect(user.method(:save).owner).not_to be Email
    end
  end

  # --- the prefix (ADR-0016) -------------------------------------------------
  #
  # The default is `#{reader}_#{method}`; `prefix: false` is bare. The rule is
  # uniform: behaviour is prefixed exactly as attributes are, and a verb that
  # reads badly prefixed is reached through the reader instead.
  describe "the prefix" do
    it "prefixes every delegated name with the component reader by default" do
      user = User.new

      expect(user).to respond_to(:email_address, :email_address=, :email_verified, :email_verified=)
      expect(user).to respond_to(:name_first, :name_last, :name_full_name, :name_initials)
    end

    it "prefixes behaviour exactly as it prefixes attributes" do
      # Uniform, deliberately: an attributes-only rule would need a heuristic
      # for what counts as an attribute and would reopen verb collisions. The
      # ugly form is always avoidable through the reader.
      user = User.create!

      expect(user.email_send_welcome_email).to eq :sent
      expect(user.email.send_welcome_email).to eq :sent
      expect(user).not_to respond_to :send_welcome_email
    end

    it "does not define the bare names" do
      user = User.new

      expect(user).not_to respond_to(:address, :address=, :verified, :first, :last, :initials)
    end

    it "leaves the reader and the presence predicate unprefixed" do
      user = User.new

      expect(user).to respond_to(:email, :email?, :name, :name?)
    end

    it "lets two components share an attribute name without a conflict" do
      # The payoff. Name#title and Group#title were the RFC-0005 conflict that
      # forced `except: [:title]`; prefixed, they coexist with no option at all.
      stub_const("Both", Class.new(ApplicationEntity))
      Both.component Name

      expect { Both.component Group }.not_to raise_error

      both = Both.new
      both.group_title = "Ops"
      expect(both.name_title).to eq "from Name"
      expect(both.group_title).to eq "Ops"
    end

    it "frees the reader namespace for a component named after a field" do
      # Email#address used to delegate as `address`, which is exactly the reader
      # the Address component wants. Prefixed, `address` is free.
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email

      expect { Solo.component Address }.not_to raise_error
      expect(Solo.new.address).to be_an Address
      expect(Solo.new.email_address).to be_nil
    end

    describe "prefix: false" do
      it "delegates the bare names" do
        stub_const("Bare", Class.new(ApplicationEntity))
        Bare.component Email, prefix: false

        expect(Bare.new).to respond_to(:address, :address=, :verified, :verified=, :send_welcome_email)
        expect(Bare.new).not_to respond_to(:email_address)
      end

      it "routes the bare writer through the same reader" do
        stub_const("Bare", Class.new(ApplicationEntity))
        Bare.component Email, prefix: false

        bare = Bare.create!
        bare.address = "a@b.com"

        expect(bare.email.address).to eq "a@b.com"
      end

      it "combines with except:" do
        stub_const("Bare", Class.new(ApplicationEntity))
        Bare.component Email, prefix: false, except: [:verified]

        expect(Bare.new).to respond_to(:address)
        expect(Bare.new).not_to respond_to(:verified)
      end

      it "combines with only:" do
        stub_const("Bare", Class.new(ApplicationEntity))
        Bare.component Email, prefix: false, only: [:address]

        expect(Bare.new).to respond_to(:address, :address=)
        expect(Bare.new).not_to respond_to(:verified, :send_welcome_email)
      end

      it "is recorded in the registry so conflict detection re-derives the same names" do
        stub_const("Bare", Class.new(ApplicationEntity))
        Bare.component Email, prefix: false

        expect(EcsRails.registry.components_for(Bare).first.options).to eq(prefix: false)
      end

      it "does not conflict with a prefixed sibling sharing the attribute" do
        # Name bare delegates `title`; Group prefixed delegates `group_title`.
        stub_const("Mixed", Class.new(ApplicationEntity))
        Mixed.component Name, prefix: false

        expect { Mixed.component Group }.not_to raise_error
        expect(Mixed.new.title).to eq "from Name"
        expect(Mixed.new).to respond_to :group_title
      end
    end

    describe "prefix: true" do
      it "is the default, and is not recorded" do
        stub_const("Explicit", Class.new(ApplicationEntity))
        Explicit.component Email, prefix: true

        expect(Explicit.new).to respond_to :email_address
        expect(EcsRails.registry.components_for(Explicit).first.options).to eq({})
      end
    end

    describe "a label" do
      # A Symbol is RFC-0014's slot label: `prefix: :business` declares the
      # component into slot "business" with reader `business_address` and
      # delegation `business_address_line1`. That is spec/slots_spec.rb's
      # subject; here it is enough to pin that the one `prefix:` keyword carries
      # both meanings without ambiguity.
      it "is a slot, prefixed with its own reader" do
        stub_const("Slotted", Class.new(ApplicationEntity))
        Slotted.component Address, prefix: :business

        expect(Slotted.new).to respond_to(:business_address, :business_address_line1)
        expect(Slotted.new).not_to respond_to(:address, :address_line1)
      end

      it "rejects anything that is not a Boolean or a label" do
        stub_const("Slotted", Class.new(ApplicationEntity))

        expect { Slotted.component Email, prefix: 42 }
          .to raise_error(ArgumentError, /prefix:.*RFC-0014.*42/m)
        expect(Slotted.new).not_to respond_to :email
      end
    end
  end

  # --- the delegated set -----------------------------------------------------
  #
  # THE CRUX for everything downstream (RFC-0007, the demo). The delegated set
  # is the component's public instance methods AND its attribute accessors,
  # minus everything EcsRails::Component and its ancestors define, minus the
  # identity columns — each prefixed with the reader. Pinned exactly, per
  # attribute, so a widening of the boundary (e.g. AR dirty-tracking helpers
  # leaking in) fails loudly.
  describe "the delegated set" do
    it "delegates a plain public method" do
      expect(User.new).to respond_to :email_send_welcome_email
    end

    it "delegates an attribute reader and its writer" do
      expect(User.new).to respond_to(:email_address, :email_address=, :email_verified, :email_verified=)
    end

    it "delegates a method the component gains from an included module" do
      # #initials comes from Nameable, not Name's class body — the boundary the
      # RFC warns instance_methods(false) would miss.
      expect(User.new).to respond_to :name_initials
    end

    it "does not delegate the identity columns" do
      # entity_id and the component timestamps are the component's identity, not
      # its state — never delegated, prefixed or otherwise.
      user = User.new

      expect(user).not_to respond_to(:email_entity_id, :email_entity_id=)
      expect(user).not_to respond_to(:email_updated_at, :email_created_at, :email_id)
    end

    it "does not delegate ActiveRecord persistence methods" do
      # `save`/`reload` exist on the entity (it is an AR model) but must come
      # from AR, never from a component — hence the owner check, not respond_to.
      user = User.new

      expect(user.method(:save).owner).not_to eq User.generated_component_methods
      expect(user.method(:reload).owner).not_to eq User.generated_component_methods
    end

    # The exact set, pinned. If this changes, RFC-0007 and the demo change with
    # it — so it changes here first, deliberately.
    it "delegates exactly Email's own methods and state accessors, prefixed" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email
      generated = Solo.generated_component_methods.instance_methods(false).sort

      # #email is the reader (RFC-0006); #email? is the presence predicate
      # (RFC-0009); everything else is Email's delegation under ADR-0016.
      expect(generated).to eq %i[
        email email? email_address email_address= email_send_welcome_email
        email_verified email_verified= email_who_am_i
      ]
    end

    it "delegates exactly Name's own methods and state accessors, prefixed" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Name
      generated = Solo.generated_component_methods.instance_methods(false).sort

      # #name is the reader; #name? is the presence predicate (RFC-0009).
      expect(generated).to eq %i[
        name name? name_combine name_first name_first= name_full_name name_initials
        name_last name_last= name_title name_title=
      ]
    end

    it "delegates exactly Email's bare set under prefix: false" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email, prefix: false
      generated = Solo.generated_component_methods.instance_methods(false).sort

      expect(generated)
        .to eq %i[address address= email email? send_welcome_email verified verified= who_am_i]
    end
  end

  # --- forwarding ------------------------------------------------------------
  #
  # RFC-0005: delegation forwards *args, **kwargs and &block untouched.
  describe "argument forwarding" do
    let(:user) { User.create! }

    it "forwards positional args, a keyword arg and a block together" do
      user.name_first = "ignored" # #combine reads its args, not the component's state

      expect(user.name_combine("a", "b", separator: "+") { |s| s.upcase }).to eq "A+B"
    end

    it "forwards no arguments cleanly to a zero-arity method" do
      expect(user.email_send_welcome_email).to eq :sent
    end
  end

  # --- the RFC-0006 integration: the money path ------------------------------
  #
  # Delegation targets the lazy reader (RFC-0006), so a delegated writer must
  # dirty the very instance the save cascade later persists. This is the seam
  # between the two RFCs and the thing most likely to be subtly broken.
  describe "writing through delegation" do
    it "reads back an assignment from the same virtual instance" do
      user = User.create!
      user.email_address = "a@b.com"

      expect(user.email_address).to eq "a@b.com"
      expect(user.email.address).to eq "a@b.com"
    end

    it "dirties the same instance the reader hands out" do
      user = User.create!
      user.email_address = "a@b.com"

      expect(user.email).to be_ecs_dirty
    end

    it "persists through the cascade with exactly one INSERT" do
      user = User.create!
      user.email_address = "a@b.com"

      sql = capture_sql { user.save! }
      expect(sql.grep(/INSERT INTO "emails"/).size).to eq 1
    end

    it "inserts exactly one row" do
      user = User.create!
      user.email_address = "a@b.com"

      expect { user.save! }.to change(Email, :count).by(1)
    end

    it "reads the persisted value back after reload" do
      user = User.create!
      user.email_address = "a@b.com"
      user.save!

      expect(user.reload.email_address).to eq "a@b.com"
    end

    it "inserts nothing when the delegated writer assigns the default" do
      user = User.create!
      user.email_verified = false # false is the default

      expect(capture_sql { user.save! }.grep(/emails/)).to be_empty
    end
  end

  # --- flat mass assignment (ECS-12, emergent) -------------------------------
  #
  # Because the prefixed writers exist, ActiveRecord's assign_attributes routes
  # a flat hash to the right component for free — `User.create!(name_first:
  # "Ada", email_address: "a@b.com")` — through the lazy reader (so the instance
  # is the one the cascade saves) and the save cascade (so it persists). This
  # is the inverse of the flat serialization ECS-2 will add. Pinned on new,
  # create and update, plus the two edges: unknown keys still raise, and Rails
  # multiparameter form fields route too.
  describe "flat mass assignment" do
    it "routes prefixed keys to the right components on new" do
      user = User.new(name_first: "Ada", email_address: "a@b.com")

      expect(user.name.first).to eq "Ada"
      expect(user.email.address).to eq "a@b.com"
    end

    it "dirties the components it assigns" do
      user = User.new(name_first: "Ada", email_address: "a@b.com")

      expect(user.name).to be_ecs_dirty
      expect(user.email).to be_ecs_dirty
      expect(user.group).not_to be_ecs_dirty
    end

    it "persists them through the cascade on create" do
      user = User.create!(name_first: "Ada", email_address: "a@b.com")

      user.reload
      expect(user.name_first).to eq "Ada"
      expect(user.email_address).to eq "a@b.com"
    end

    it "inserts exactly one row per assigned component on create" do
      expect { User.create!(name_first: "Ada", email_address: "a@b.com") }
        .to change(Name, :count).by(1).and change(Email, :count).by(1)
    end

    it "inserts nothing for components it did not touch" do
      expect { User.create!(name_first: "Ada") }.not_to change(Group, :count)
    end

    it "routes prefixed keys on update" do
      user = User.create!(name_first: "Ada")
      user.update!(name_first: "Grace", email_address: "g@b.com")

      user.reload
      expect(user.name_first).to eq "Grace"
      expect(user.email_address).to eq "g@b.com"
    end

    it "round-trips a bare key for a prefix: false component" do
      stub_const("Bare", Class.new(ApplicationEntity))
      Bare.component Email, prefix: false

      expect(Bare.create!(address: "a@b.com").reload.email.address).to eq "a@b.com"
    end

    it "routes a relationship writer, which is bare by design" do
      # relates_to declares its backing component with prefix: false, so the
      # flat key is the relationship name — `Post.new(author: user)`.
      user = User.create!
      post = Post.create!(author: user)

      expect(post.reload.author).to eq user
    end

    it "still raises on a key nothing answers" do
      expect { User.new(nope: 1) }.to raise_error(ActiveModel::UnknownAttributeError, /nope/)
    end

    it "still raises on a component key that is not prefixed" do
      # `address:` is no longer a writer on User; only `email_address:` is. The
      # error is the ordinary ActiveModel one, so a form posting stale bare keys
      # fails the way any Rails developer expects.
      expect { User.new(address: "a@b.com") }.to raise_error(ActiveModel::UnknownAttributeError, /address/)
    end

    it "routes Rails multiparameter form fields" do
      # date_select posts `group_founded_on(1i)`, `(2i)`, `(3i)`. ActiveRecord
      # folds those into one Hash and sends it to `group_founded_on=`, which is
      # a delegated writer here; the component's own date type casts the Hash.
      # The ECS-12 issue flagged this as an edge that might not route — it does.
      user = User.new(
        "group_founded_on(1i)" => "2020",
        "group_founded_on(2i)" => "3",
        "group_founded_on(3i)" => "4"
      )

      expect(user.group.founded_on).to eq Date.new(2020, 3, 4)
      expect(user.group).to be_ecs_dirty
    end
  end

  # --- conflicts (ADR-0004) --------------------------------------------------
  #
  # The backstop. Two components delegating the same *entity-level* name is a
  # clash at declaration time, naming both components, the method and the fix.
  # No silent winner, ever. Under ADR-0016 that takes two bare components — so
  # every example here forces `prefix: false` on both.
  describe "conflicts" do
    it "names the method, both components and the entity" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name, prefix: false

      expect { Clash.component Group, prefix: false }
        .to raise_error(EcsRails::DelegationConflict) do |error|
          expect(error.message).to include "#title", "Name", "Group", "Clash"
        end
    end

    it "points at the except: escape hatch in the message" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name, prefix: false

      expect { Clash.component Group, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /except: \[:title\]/)
    end

    it "raises when the clash is declared, not when the method is called" do
      # Declaring in the opposite order still fails at the second `component`.
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Group, prefix: false

      expect { Clash.component Name, prefix: false }
        .to raise_error(EcsRails::DelegationConflict)
    end

    it "leaves the class unchanged when a declaration conflicts" do
      # The reader for the rejected component is never defined, and the registry
      # never records it — the conflict fails before any of that.
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name, prefix: false

      begin
        Clash.component Group, prefix: false
      rescue EcsRails::DelegationConflict
        # expected
      end

      expect(Clash.new).not_to respond_to :group
      expect(EcsRails.registry.components_for(Clash).map(&:component_class)).to eq [Name]
    end

    it "does not treat an entity-defined method as a conflict" do
      # ADR-0004: a method on the entity itself wins silently. Email delegates
      # #email_address; the entity also defines it; both components delegating
      # the same name is a conflict, but a component-vs-entity overlap is not.
      stub_const("Winner", Class.new(ApplicationEntity) do
        def email_address
          "entity wins"
        end
      end)

      expect { Winner.component Email }.not_to raise_error
      expect(Winner.create!.email_address).to eq "entity wins"
    end

    it "does not conflict on the writer once except: removes the attribute" do
      # `except: [:title]` names the attribute, so it removes both #title and
      # #title= — otherwise the writer would still clash and this would raise.
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name, prefix: false

      expect { Resolved.component Group, prefix: false, except: [:title] }.not_to raise_error
    end
  end

  # A component reader name is reserved. A method delegated from the component
  # that would take the reader's name used to silently overwrite the reader and
  # recurse forever (SystemStackError). Surfaced building the demo with a
  # relationship component named for its own association (ADR-0006).
  #
  # Under ADR-0016 the default prefix makes this structurally impossible — a
  # prefixed name starts with the reader plus an underscore, so it can never
  # equal it — which is why `prefix: false` is needed to reproduce it.
  describe "a delegated method colliding with a component reader" do
    it "cannot happen under the default prefix" do
      # Sponsor's reader is `sponsor`; its belongs_to :sponsor is delegated as
      # `sponsor_sponsor`. Both exist, neither shadows the other.
      stub_const("Team", Class.new(ApplicationEntity))

      expect { Team.component Sponsor }.not_to raise_error

      team = Team.create!
      expect(team.sponsor).to be_a Sponsor
      expect(team.sponsor_sponsor).to be_nil
      expect(team.sponsor_sponsor_id).to be_nil
    end

    it "raises at declaration instead of recursing when bare" do
      stub_const("Team", Class.new(ApplicationEntity))

      expect { Team.component Sponsor, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /reader/)
    end

    it "names the fixes in the message" do
      stub_const("Team", Class.new(ApplicationEntity))

      expect { Team.component Sponsor, prefix: false }
        .to raise_error(EcsRails::DelegationConflict) do |error|
          expect(error.message).to include "prefix: false", "sponsor_sponsor", "except: [:sponsor]", "belongs_to"
        end
    end

    it "resolves cleanly when the colliding method is excepted" do
      # `except: [:sponsor]` drops the belongs_to reader/writer, so the component
      # reader survives and `team.sponsor` returns the Sponsor component.
      stub_const("Team", Class.new(ApplicationEntity))
      Team.component Sponsor, prefix: false, except: [:sponsor]

      team = Team.create!
      expect(team.sponsor).to be_a Sponsor
      expect(team.sponsor.sponsor_id).to be_nil
    end

    it "leaves the class unchanged when it raises" do
      stub_const("Team", Class.new(ApplicationEntity))
      begin
        Team.component Sponsor, prefix: false
      rescue EcsRails::DelegationConflict
        # expected
      end
      expect(Team.new).not_to respond_to :sponsor
      expect(EcsRails.registry.components_for(Team)).to be_empty
    end
  end

  # --- except: / only: resolution --------------------------------------------
  #
  # Both name the COMPONENT's methods (`:title`), never the prefixed entity-level
  # name (`:group_title`): they are about which of the component's methods are
  # delegated, and the prefix is applied afterwards.
  describe "except:" do
    it "lets the surviving component's method win" do
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name, prefix: false
      Resolved.component Group, prefix: false, except: [:title]

      expect(Resolved.new.title).to eq "from Name"
    end

    it "removes the excepted attribute's writer as well as its reader" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).not_to respond_to(:group_title)
      expect(Solo.new).not_to respond_to(:group_title=)
    end

    it "keeps the reader even when a method is excepted (RFC-0004)" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).to respond_to :group
    end

    it "still delegates the component's other methods" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).to respond_to(:group_description, :group_description=)
    end
  end

  describe "only:" do
    it "delegates only the named methods and their writers" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email, only: [:address]

      expect(Solo.new).to respond_to(:email_address, :email_address=)
      expect(Solo.new).not_to respond_to(:email_verified)
      expect(Solo.new).not_to respond_to(:email_send_welcome_email)
    end

    it "delegates a named plain method with no writer" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email, only: [:send_welcome_email]

      expect(Solo.new).to respond_to :email_send_welcome_email
      expect(Solo.new).not_to respond_to :email_address
    end
  end

  # --- validating only: / except: names --------------------------------------
  #
  # DECISION: an unknown name raises, at declaration time. RFC-0004 left these
  # inert and unvalidated (`except: [:titel]` registered and did nothing); the
  # RFC's Notes hand the decision to RFC-0005. Raising is the choice ADR-0004's
  # fail-loudly philosophy demands: a typo'd `except:` silently fails to resolve
  # a conflict, and a typo'd `only:` silently delegates nothing — both are the
  # action-at-a-distance ADR-0004 exists to prevent. In v0.1 a component is one
  # shared class with a fixed method set, so an unknown name is always a mistake.
  describe "validating only:/except: names" do
    it "rejects an except: naming a method the component does not delegate" do
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Group, except: [:titel] }
        .to raise_error(ArgumentError, /titel/)
    end

    it "rejects an only: naming a method the component does not delegate" do
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Email, only: [:addres] }
        .to raise_error(ArgumentError, /addres/)
    end

    it "rejects the prefixed entity-level name, because options name the component's methods" do
      # `except: [:group_title]` is the natural mistake after ADR-0016. It is a
      # mistake: Group has no #group_title. The error lists what it does have.
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Group, except: [:group_title] }
        .to raise_error(ArgumentError, /group_title.*#title/m)
    end

    it "rejects excepting an identity column that is never delegated" do
      # entity_id is not in the delegable set, so naming it is meaningless — and
      # meaningless-but-silent is exactly what this validation refuses.
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Email, except: [:entity_id] }
        .to raise_error(ArgumentError, /entity_id/)
    end

    it "leaves the class unchanged when a name is rejected" do
      stub_const("Solo", Class.new(ApplicationEntity))

      begin
        Solo.component Email, except: [:titel]
      rescue ArgumentError
        # expected
      end

      expect(Solo.new).not_to respond_to :email
      expect(EcsRails.registry.components_for(Solo)).to eq []
    end

    it "accepts the writer form of a real attribute" do
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Email, except: [:address=] }.not_to raise_error
      # Naming the writer removes the whole accessor pair.
      expect(Solo.new).not_to respond_to(:email_address, :email_address=)
    end
  end

  # --- inheritance -----------------------------------------------------------
  describe "inheritance" do
    it "delegates a component declared on a parent entity" do
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.component Email
      stub_const("Child", Class.new(Parent))

      expect(Child.create!.email_send_welcome_email).to eq :sent
    end

    it "raises when a subclass declares a bare component clashing with the parent's" do
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.component Name, prefix: false
      stub_const("Child", Class.new(Parent))

      expect { Child.component Group, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /#title.*Name.*Group/)
    end

    it "honours the parent's prefix: false when checking a subclass for conflicts" do
      # The option lives in the registry with the parent's declaration, and the
      # subclass walk re-derives the parent's bare names from it.
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.component Name, prefix: false
      stub_const("Child", Class.new(Parent))

      expect { Child.component Group }.not_to raise_error
      expect(Child.new.title).to eq "from Name"
      expect(Child.new).to respond_to :group_title
    end
  end

  # --- reload safety ---------------------------------------------------------
  #
  # In development Rails drops the constant and autoloads a new Class under the
  # same name, and the Railtie clears the registry — so every declaration runs
  # again, on a fresh class. Re-declaring must not raise a spurious conflict.
  describe "surviving a class reload" do
    it "re-generates delegation on the new class without raising" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).component Email
      EcsRails.registry.clear!
      reloaded = stub_const("Reloadable", Class.new(ApplicationEntity))

      expect { reloaded.component Email }.not_to raise_error
      expect(reloaded.create!.email_send_welcome_email).to eq :sent
    end
  end
end
