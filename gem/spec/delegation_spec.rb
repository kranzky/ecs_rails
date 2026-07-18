# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0005: method delegation from an entity to its components.
#
# This is where the proposal's headline sugar becomes real:
#
#   user.send_welcome_email   # => user.email.send_welcome_email
#   user.address = "a@b.com"  # => user.email.address = "a@b.com"
#
# The governing rule is ADR-0004: two components exposing the same name is a
# DelegationConflict raised at *declaration* time, never a silent last-wins.
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
  # Copied from the RFC. These are the contract. `user` here is the host app's
  # User (spec/support/models.rb), except where a test needs a bespoke entity.
  describe "the RFC's contract" do
    let(:user) { User.create! }

    it "delegates a component method" do
      expect(user.send_welcome_email).to eq :sent
    end

    it "binds self to the component, not the entity" do
      expect(user.who_am_i).to be_an Email
    end

    it "delegates attribute writers" do
      user.address = "a@b.com"

      expect(user.email.address).to eq "a@b.com"
    end

    it "raises on a conflict at declaration time" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name

      expect { Clash.component Group }
        .to raise_error(EcsRails::DelegationConflict, /#title.*Name.*Group/)
    end

    it "lets except: resolve a conflict" do
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name
      Resolved.component Group, except: [:title]

      expect(Resolved.new.title).to eq "from Name"
    end

    it "prefers a method defined on the entity itself" do
      stub_const("Winner", Class.new(ApplicationEntity) do
        def address
          "entity wins"
        end
      end)
      Winner.component Email

      expect(Winner.create!.address).to eq "entity wins"
    end

    it "does not delegate ActiveRecord plumbing" do
      expect(user.method(:save).owner).not_to be Email
    end
  end

  # --- the delegated set -----------------------------------------------------
  #
  # THE CRUX for everything downstream (RFC-0007, the demo). The delegated set
  # is the component's public instance methods AND its attribute accessors,
  # minus everything EcsRails::Component and its ancestors define, minus the
  # identity columns. Pinned exactly, per attribute, so a widening of the
  # boundary (e.g. AR dirty-tracking helpers leaking in) fails loudly.
  describe "the delegated set" do
    it "delegates a plain public method" do
      expect(User.new).to respond_to :send_welcome_email
    end

    it "delegates an attribute reader and its writer" do
      expect(User.new).to respond_to(:address, :address=, :verified, :verified=)
    end

    it "delegates a method the component gains from an included module" do
      # #initials comes from Nameable, not Name's class body — the boundary the
      # RFC warns instance_methods(false) would miss.
      expect(User.new).to respond_to :initials
    end

    it "does not delegate the identity columns" do
      # entity_id and the component timestamps are the component's identity, not
      # its state — never delegated. (created_at is not checked here: the entity
      # has its own created_at column, so it responds for reasons unrelated to
      # delegation. That component timestamps stay out of the generated module is
      # pinned by the exact-set tests below.)
      user = User.new

      expect(user).not_to respond_to(:entity_id)
      expect(user).not_to respond_to(:entity_id=)
      expect(user).not_to respond_to(:updated_at)
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
    it "delegates exactly Email's own methods and state accessors" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email
      generated = Solo.generated_component_methods.instance_methods(false).sort

      # #email is the reader (RFC-0006); everything else is Email's delegation.
      expect(generated).to eq %i[address address= email send_welcome_email verified verified= who_am_i]
    end

    it "delegates exactly Name's own methods and state accessors" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Name
      generated = Solo.generated_component_methods.instance_methods(false).sort

      expect(generated)
        .to eq %i[combine first first= full_name initials last last= name title title=]
    end
  end

  # --- forwarding ------------------------------------------------------------
  #
  # RFC-0005: delegation forwards *args, **kwargs and &block untouched.
  describe "argument forwarding" do
    let(:user) { User.create! }

    it "forwards positional args, a keyword arg and a block together" do
      user.first = "ignored" # #combine reads its args, not the component's state

      expect(user.combine("a", "b", separator: "+") { |s| s.upcase }).to eq "A+B"
    end

    it "forwards no arguments cleanly to a zero-arity method" do
      expect(user.send_welcome_email).to eq :sent
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
      user.address = "a@b.com"

      expect(user.address).to eq "a@b.com"
      expect(user.email.address).to eq "a@b.com"
    end

    it "dirties the same instance the reader hands out" do
      user = User.create!
      user.address = "a@b.com"

      expect(user.email).to be_ecs_dirty
    end

    it "persists through the cascade with exactly one INSERT" do
      user = User.create!
      user.address = "a@b.com"

      sql = capture_sql { user.save! }
      expect(sql.grep(/INSERT INTO "emails"/).size).to eq 1
    end

    it "inserts exactly one row" do
      user = User.create!
      user.address = "a@b.com"

      expect { user.save! }.to change(Email, :count).by(1)
    end

    it "reads the persisted value back after reload" do
      user = User.create!
      user.address = "a@b.com"
      user.save!

      expect(user.reload.address).to eq "a@b.com"
    end

    it "inserts nothing when the delegated writer assigns the default" do
      user = User.create!
      user.verified = false # false is the default

      expect(capture_sql { user.save! }.grep(/emails/)).to be_empty
    end
  end

  # --- conflicts (ADR-0004) --------------------------------------------------
  #
  # The heart of the RFC. A clash raises at declaration time, naming both
  # components, the method and the fix. No silent winner, ever.
  describe "conflicts" do
    it "names the method, both components and the entity" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name

      expect { Clash.component Group }
        .to raise_error(EcsRails::DelegationConflict) do |error|
          expect(error.message).to include "#title", "Name", "Group", "Clash"
        end
    end

    it "points at the except: escape hatch in the message" do
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name

      expect { Clash.component Group }
        .to raise_error(EcsRails::DelegationConflict, /except: \[:title\]/)
    end

    it "raises when the clash is declared, not when the method is called" do
      # Declaring in the opposite order still fails at the second `component`.
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Group

      expect { Clash.component Name }
        .to raise_error(EcsRails::DelegationConflict)
    end

    it "leaves the class unchanged when a declaration conflicts" do
      # The reader for the rejected component is never defined, and the registry
      # never records it — the conflict fails before any of that.
      stub_const("Clash", Class.new(ApplicationEntity))
      Clash.component Name

      begin
        Clash.component Group
      rescue EcsRails::DelegationConflict
        # expected
      end

      expect(Clash.new).not_to respond_to :group
      expect(EcsRails.registry.components_for(Clash).map(&:component_class)).to eq [Name]
    end

    it "does not treat an entity-defined method as a conflict" do
      # ADR-0004: a method on the entity itself wins silently. Email delegates
      # #address; the entity also defines it; both components delegating the
      # same name is a conflict, but a component-vs-entity overlap is not.
      stub_const("Winner", Class.new(ApplicationEntity) do
        def address
          "entity wins"
        end
      end)

      expect { Winner.component Email }.not_to raise_error
      expect(Winner.create!.address).to eq "entity wins"
    end

    it "does not conflict on the writer once except: removes the attribute" do
      # `except: [:title]` names the attribute, so it removes both #title and
      # #title= — otherwise the writer would still clash and this would raise.
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name

      expect { Resolved.component Group, except: [:title] }.not_to raise_error
    end
  end

  # A component reader name is reserved. A method delegated from the component
  # that would take the reader's name used to silently overwrite the reader and
  # recurse forever (SystemStackError). Surfaced building the demo with a
  # relationship component named for its own association (ADR-0006).
  describe "a delegated method colliding with a component reader" do
    it "raises at declaration instead of recursing" do
      # Sponsor's reader is `sponsor`; its belongs_to :sponsor also defines
      # `sponsor`. Delegating it would shadow the reader.
      stub_const("Team", Class.new(ApplicationEntity))

      expect { Team.component Sponsor }
        .to raise_error(EcsRails::DelegationConflict, /reader/)
    end

    it "names the fix in the message" do
      stub_const("Team", Class.new(ApplicationEntity))

      expect { Team.component Sponsor }
        .to raise_error(EcsRails::DelegationConflict, /except: \[:sponsor\]|belongs_to/)
    end

    it "resolves cleanly when the colliding method is excepted" do
      # `except: [:sponsor]` drops the belongs_to reader/writer, so the component
      # reader survives and `team.sponsor` returns the Sponsor component.
      stub_const("Team", Class.new(ApplicationEntity))
      Team.component Sponsor, except: [:sponsor]

      team = Team.create!
      expect(team.sponsor).to be_a Sponsor
      expect(team.sponsor.sponsor_id).to be_nil
    end

    it "leaves the class unchanged when it raises" do
      stub_const("Team", Class.new(ApplicationEntity))
      begin
        Team.component Sponsor
      rescue EcsRails::DelegationConflict
        # expected
      end
      expect(Team.new).not_to respond_to :sponsor
      expect(EcsRails.registry.components_for(Team)).to be_empty
    end
  end

  # --- except: / only: resolution --------------------------------------------
  describe "except:" do
    it "lets the surviving component's method win" do
      stub_const("Resolved", Class.new(ApplicationEntity))
      Resolved.component Name
      Resolved.component Group, except: [:title]

      expect(Resolved.new.title).to eq "from Name"
    end

    it "removes the excepted attribute's writer as well as its reader" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).not_to respond_to(:title)
      expect(Solo.new).not_to respond_to(:title=)
    end

    it "keeps the reader even when a method is excepted (RFC-0004)" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).to respond_to :group
    end

    it "still delegates the component's other methods" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Group, except: [:title]

      expect(Solo.new).to respond_to(:description, :description=)
    end
  end

  describe "only:" do
    it "delegates only the named methods and their writers" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email, only: [:address]

      expect(Solo.new).to respond_to(:address, :address=)
      expect(Solo.new).not_to respond_to(:verified)
      expect(Solo.new).not_to respond_to(:send_welcome_email)
    end

    it "delegates a named plain method with no writer" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Email, only: [:send_welcome_email]

      expect(Solo.new).to respond_to :send_welcome_email
      expect(Solo.new).not_to respond_to :address
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
      expect(Solo.new).not_to respond_to(:address, :address=)
    end
  end

  # --- inheritance -----------------------------------------------------------
  describe "inheritance" do
    it "delegates a component declared on a parent entity" do
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.component Email
      stub_const("Child", Class.new(Parent))

      expect(Child.create!.send_welcome_email).to eq :sent
    end

    it "raises when a subclass declares a component clashing with the parent's" do
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.component Name
      stub_const("Child", Class.new(Parent))

      expect { Child.component Group }
        .to raise_error(EcsRails::DelegationConflict, /#title.*Name.*Group/)
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
      expect(reloaded.create!.send_welcome_email).to eq :sent
    end
  end
end
