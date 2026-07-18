# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0006: lazy / virtual components, and closes the gap RFC-0004
# knowingly left in architecture.md §3 ("entity.email always returns an Email
# instance, never nil").
#
# This is the feature the gem's central claim rests on: *components are free
# unless you use them*. "Free" is a claim about SQL, so most of these examples
# assert the absence of statements rather than the presence of values — that is
# the only way to tell the design from one that merely looks like it.
RSpec.describe "lazy components" do
  # Statements issued while the block runs. Same helper as dsl_spec.rb.
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

  # --- RFC-0006's own example tests ------------------------------------------
  #
  # Copied verbatim from the RFC. These are the contract.
  describe "the RFC's contract" do
    it "returns a virtual component when no row exists" do
      user = User.create!

      expect(user.email).to be_present
      expect(user.email).not_to be_persisted
    end

    it "does not insert a row on read" do
      user = User.create!

      expect { user.email.address }.not_to change(Email, :count)
    end

    it "inserts a row once dirtied and saved" do
      user = User.create!
      user.email.address = "a@b.com"

      expect { user.save! }.to change(Email, :count).by(1)
    end

    it "does not insert when assigned the default value" do
      user = User.create!
      user.email.verified = false # false is the default

      expect { user.save! }.not_to change(Email, :count)
    end

    it "memoises within one entity instance" do
      user = User.create!

      expect(user.email).to equal user.email
    end

    it "reverts to virtual after destroy" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.destroy

      expect(user.reload.email).not_to be_persisted
      expect(user.email.address).to be_nil
    end
  end

  # --- the reader ------------------------------------------------------------
  #
  # architecture.md §3: `entity.email` **always** returns an Email instance.
  describe "the reader" do
    it "returns an instance of the component class, not nil" do
      expect(User.create!.email).to be_an Email
    end

    it "returns the row when one exists" do
      user = User.create!
      email = Email.create!(entity: user, address: "a@b.com")

      expect(user.email).to eq email
      expect(user.email).to be_persisted
    end

    it "reports every attribute at its database default" do
      email = User.create!.email

      expect(email.address).to be_nil
      expect(email.verified).to be false
    end

    # "Defaults come from the database column defaults, so Email.new.address and
    # a virtual user.email.address agree by construction" (RFC-0006).
    it "agrees with a bare Email.new, by construction" do
      virtual = User.create!.email

      expect(virtual.attributes.except("id", "entity_id"))
        .to eq Email.new.attributes.except("id", "entity_id")
    end

    it "sets entity_id on the virtual component" do
      user = User.create!

      expect(user.email.entity_id).to eq user.id
    end

    it "is virtual for every declared component, not just the tested one" do
      user = User.create!

      expect([user.name, user.group]).to all(be_present)
      expect([user.name, user.group]).to all(satisfy { |c| !c.persisted? })
    end

    # RFC-0004: only:/except: restrict delegation, never the reader.
    it "returns a virtual component even when methods are excluded" do
      expect(User.create!.group).to be_a Group
    end

    it "works on a new, unsaved entity" do
      expect(User.new.email).to be_an Email
    end

    it "works on a sub-subclass of the declaring entity" do
      stub_const("Manager", Class.new(User))

      expect(Manager.create!.email).to be_an Email
    end
  end

  # --- reaching back to the entity -------------------------------------------
  #
  # A virtual component has no row, so there is nothing to query *from* — the
  # entity must be handed over directly or `component.entity` is a nil deref.
  describe "a virtual component's entity" do
    it "is the entity that built it" do
      user = User.create!

      expect(user.email.entity).to equal user
    end

    it "costs no query" do
      user = User.create!
      email = user.email

      expect(capture_sql { email.entity }).to be_empty
    end
  end

  # --- memoisation -----------------------------------------------------------
  #
  # Without this the money path is impossible: a reader that built a fresh
  # instance per call would throw away the caller's assignment.
  describe "memoisation" do
    it "returns the same object on repeated reads" do
      user = User.create!

      expect(user.email).to equal user.email
    end

    it "keeps an assignment made through the reader" do
      user = User.create!
      user.email.address = "a@b.com"

      expect(user.email.address).to eq "a@b.com"
    end

    it "queries for the row only once" do
      user = User.create!
      user.email

      expect(capture_sql { user.email }).to be_empty
    end

    it "does not share the memo between two instances of the same entity" do
      user = User.create!
      other = User.find(user.id)

      expect(user.email).not_to equal other.email
    end

    it "does not share the memo between different components" do
      user = User.create!

      expect(user.email).not_to equal user.name
    end

    # The memo must not outlive the association cache, or reload is a lie.
    it "is cleared by reload" do
      user = User.create!
      before = user.email

      expect(user.reload.email).not_to equal before
    end

    it "picks up a row inserted behind its back after reload" do
      user = User.create!
      user.email # memoise a virtual
      Email.create!(entity: user, address: "a@b.com")

      expect(user.reload.email).to be_persisted
      expect(user.email.address).to eq "a@b.com"
    end

    it "returns the memoised instance after the cascade persists it" do
      user = User.create!
      email = user.email
      email.address = "a@b.com"
      user.save!

      expect(user.email).to equal email
      expect(user.email).to be_persisted
    end
  end

  # --- what "dirty" means ----------------------------------------------------
  #
  # THE CRUX. RFC-0006: the dirty check is "differs from default", *not*
  # ActiveModel's "differs from the last saved value".
  #
  # The two are not merely different after a destroy-then-reset (which is the
  # divergence the RFC calls out) — they differ immediately, on every single
  # virtual component, and in the direction that would destroy the feature.
  # Building a virtual component sets entity_id, and ActiveModel counts that as
  # a change. So `user.email.changed?` is *true* for a component nobody has
  # touched, and a cascade built on ActiveModel's dirty would insert a row for
  # every component ever read.
  #
  # The same argument disqualifies the RFC's own wording, taken literally:
  # entity_id differs from its column default (nil) too. The FK is plumbing, not
  # state, and the rule has to say so. See EcsRails::Lazy::Component#ecs_dirty?.
  describe "dirty" do
    it "is not ActiveModel's dirty: a virtual component reports changed?" do
      user = User.create!

      expect(user.email.changed?).to be true
      expect(user.email.changes).to eq("entity_id" => [nil, user.id])
    end

    it "...but is not dirty, because entity_id is identity, not state" do
      expect(User.create!.email).not_to be_ecs_dirty
    end

    # The consequence, stated as behaviour: this is the example that would fail
    # if the cascade ever used `changed?`.
    it "so merely reading every component inserts nothing" do
      user = User.create!
      user.email
      user.name
      user.group

      expect { user.save! }.not_to change { [Email.count, Name.count, Group.count] }
    end

    it "is dirty once an attribute differs from its default" do
      user = User.create!
      user.email.address = "a@b.com"

      expect(user.email).to be_ecs_dirty
    end

    it "is not dirty when an attribute is assigned its own default" do
      user = User.create!
      user.email.verified = false

      expect(user.email).not_to be_ecs_dirty
    end

    it "is not dirty when an attribute is set and then put back to its default" do
      user = User.create!
      user.email.address = "a@b.com"
      user.email.address = nil

      expect(user.email).not_to be_ecs_dirty
    end

    it "is dirty on a non-default boolean" do
      user = User.create!
      user.email.verified = true

      expect(user.email).to be_ecs_dirty
    end

    # The divergence the RFC names. After destroy-then-reset the component is
    # back to defaults, so it is not dirty — even though it once held a value.
    it "differs from changed? after a destroy-then-reset" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.destroy

      expect(user.email).not_to be_ecs_dirty
      expect { user.save! }.not_to change(Email, :count)
    end

    # ...and the other half of the rule. "Differs from default" is the right
    # question only for a row that does not exist yet. For a row that *does*,
    # the question is ActiveModel's — otherwise clearing an attribute back to
    # its default would silently discard the UPDATE.
    it "uses ActiveModel's dirty once the row exists" do
      user = User.create!
      user.name.update!(first: "Ada")
      user.name.first = nil # back to the column default...

      expect(user.name).to be_ecs_dirty # ...but this is still an UPDATE
    end

    it "persists that UPDATE rather than discarding it" do
      user = User.create!
      user.name.update!(first: "Ada")
      user.name.first = nil
      user.save!

      expect(user.reload.name.first).to be_nil
      expect(user.name).to be_persisted
    end

    it "is not dirty for an unchanged persisted row" do
      user = User.create!
      user.name.update!(first: "Ada")

      expect(user.name).not_to be_ecs_dirty
    end
  end

  # --- the money path --------------------------------------------------------
  #
  # `user.email.address = "x"; user.save!` is the line the whole design exists
  # to make work. Everything above is machinery in service of these five.
  describe "the money path" do
    it "inserts exactly one row" do
      user = User.create!
      user.email.address = "a@b.com"

      expect { user.save! }.to change(Email, :count).by(1)
    end

    it "issues exactly one INSERT against emails" do
      user = User.create!
      user.email.address = "a@b.com"

      expect(capture_sql { user.save! }.grep(/INSERT INTO "emails"/).size).to eq 1
    end

    it "persists the value the caller assigned" do
      user = User.create!
      user.email.address = "a@b.com"
      user.save!

      expect(user.reload.email.address).to eq "a@b.com"
    end

    it "inserts nothing when the assignment equals the default" do
      user = User.create!
      user.email.verified = false

      expect(capture_sql { user.save! }.grep(/emails/)).to be_empty
    end

    it "works on a brand-new entity, whose id does not exist yet at read time" do
      user = User.new
      user.email.address = "a@b.com"

      expect { user.save! }.to change(Email, :count).by(1)
      expect(user.reload.email.address).to eq "a@b.com"
      expect(Email.last.entity_id).to eq user.id
    end

    it "updates rather than inserting when the row already exists" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.address = "c@d.com"

      expect { user.save! }.not_to change(Email, :count)
      expect(user.reload.email.address).to eq "c@d.com"
    end
  end

  # --- the save cascade ------------------------------------------------------

  describe "the save cascade" do
    it "saves every dirty component" do
      user = User.create!
      user.email.address = "a@b.com"
      user.name.first = "Ada"

      user.save!

      expect([Email.count, Name.count]).to eq [1, 1]
    end

    it "saves only the dirty ones" do
      user = User.create!
      user.email.address = "a@b.com"
      user.name # read, untouched

      user.save!

      expect([Email.count, Name.count]).to eq [1, 0]
    end

    it "touches no component table when nothing was read" do
      user = User.create!

      expect(capture_sql { user.save! }.grep(/emails|names|groups/)).to be_empty
    end

    it "runs on create as well as update" do
      user = User.new
      user.name.first = "Ada"

      expect { user.save! }.to change(Name, :count).by(1)
    end

    it "is idempotent — a second save inserts nothing more" do
      user = User.create!
      user.email.address = "a@b.com"
      user.save!

      expect { user.save! }.not_to change(Email, :count)
    end

    it "issues no further SQL against emails on a second save" do
      user = User.create!
      user.email.address = "a@b.com"
      user.save!

      expect(capture_sql { user.save! }.grep(/emails/)).to be_empty
    end

    it "does not resurrect a destroyed component" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      email = user.email
      email.destroy

      expect { user.save! }.not_to change(Email, :count)
    end

    it "works through save as well as save!" do
      user = User.create!
      user.email.address = "a@b.com"

      expect { user.save }.to change(Email, :count).by(1)
    end
  end

  # --- atomicity -------------------------------------------------------------
  #
  # RFC-0006: "entity.save cascades: it saves itself and every dirty component,
  # in one transaction." The observable claim is that a component failing takes
  # the entity's own INSERT down with it.
  #
  # This is only testable because spec_helper's wrapping transaction is
  # joinable: false. With a joinable one, save's transaction merges into it and
  # the rollback is silently swallowed — the entity row survives and this
  # example passes for the wrong reason. See the report.
  describe "atomicity" do
    it "rolls the entity's own insert back when a component cannot be saved" do
      user = User.new
      user.email.address = "nope" # fails Email's format validation

      expect { user.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(User.where(id: user.id).count).to eq 0
    end

    it "rolls back a sibling component that was already inserted" do
      user = User.new
      user.name.first = "Ada"
      user.email.address = "nope"

      expect { user.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(Name.count).to eq 0
    end
  end

  # --- validation ------------------------------------------------------------
  #
  # ADR-0003: a virtual, non-dirty component is not validated. RFC-0007 owns the
  # error merging; what RFC-0006 owes it is that reading a component to validate
  # it has no side effects at all.
  describe "validation" do
    it "creates an entity whose component validates presence of an attribute" do
      expect { User.create! }.not_to raise_error
    end

    it "is valid with an untouched virtual component" do
      expect(User.create!).to be_valid
    end

    it "stays valid after reading the component" do
      user = User.create!
      user.email

      expect(user).to be_valid
    end

    it "inserts nothing when validated" do
      user = User.create!
      user.email

      expect { user.valid? }.not_to change(Email, :count)
    end

    it "issues no SQL against component tables when validated" do
      user = User.create!
      user.email

      expect(capture_sql { user.valid? }.grep(/emails/)).to be_empty
    end

    it "does not dirty the component by validating the entity" do
      user = User.create!
      user.email
      user.valid?

      expect(user.email).not_to be_ecs_dirty
    end
  end

  # --- destruction -----------------------------------------------------------

  describe "component destruction" do
    it "deletes the row" do
      user = User.create!
      user.email.update!(address: "a@b.com")

      expect { user.email.destroy }.to change(Email, :count).by(-1)
    end

    # architecture.md §3: "entity.email.destroy deletes the row and **resets the
    # component to its virtual default state**. entity.email still returns an
    # instance afterwards." Note the absence of a reload — the RFC's own example
    # reloads first, which would pass without any reset at all.
    it "resets the reader to a virtual component, without a reload" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.destroy

      expect(user.email).to be_an Email
      expect(user.email).not_to be_persisted
      expect(user.email.address).to be_nil
    end

    it "does not hand back the frozen, destroyed object" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      destroyed = user.email
      destroyed.destroy

      expect(user.email).not_to equal destroyed
      expect(user.email).not_to be_frozen
    end

    it "costs no query to reset, because the row is known to be gone" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.destroy

      expect(capture_sql { user.email }).to be_empty
    end

    it "can be dirtied and saved again afterwards" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email.destroy
      user.email.address = "c@d.com"

      expect { user.save! }.to change(Email, :count).by(1)
    end

    it "leaves an unrelated entity's memo alone" do
      user = User.create!
      other = User.create!
      user.email.update!(address: "a@b.com")
      other.email.update!(address: "c@d.com")
      user.email.destroy

      expect(other.email).to be_persisted
    end

    it "tolerates a component destroyed without its entity loaded" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")

      expect { Email.first.destroy }.not_to raise_error
    end
  end

  # --- entity destruction ----------------------------------------------------
  #
  # RFC-0004 pinned that entity.destroy issues no SQL against component tables:
  # the cascade is the database's (architecture.md §3), and an ActiveRecord one
  # would mask it. Re-pinned here because RFC-0006 adds the first entity-side
  # code that knows about components at all, and it must not reach for them on
  # destroy.
  describe "entity destruction" do
    it "still removes component rows" do
      user = User.create!
      user.email.update!(address: "a@b.com")

      expect { user.destroy }.to change(Email, :count).by(-1)
    end

    it "issues no SQL against component tables, even with a memoised component" do
      user = User.create!
      user.email.update!(address: "a@b.com")
      user.email # memoised and persisted

      expect(capture_sql { user.destroy }.grep(/emails/)).to be_empty
    end

    it "issues no SQL against component tables with a dirty virtual component" do
      user = User.create!
      user.email.address = "a@b.com" # dirty, never saved

      expect(capture_sql { user.destroy }.grep(/emails/)).to be_empty
    end
  end

  # --- the plain ActiveRecord path -------------------------------------------
  #
  # RFC-0003: a component is an ordinary AR model. Laziness is the *entity's*
  # view of a component; it must not change what a component is.
  describe "the plain ActiveRecord path" do
    it "still creates a component directly" do
      user = User.create!

      expect { Email.create!(entity: user, address: "a@b.com") }
        .to change(Email, :count).by(1)
    end

    it "still validates a component created directly" do
      user = User.create!

      expect { Email.create!(entity: user) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "still requires an entity" do
      expect { Email.create!(address: "a@b.com") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "saves a bare component through the reader" do
      user = User.create!

      expect { user.email.update!(address: "a@b.com") }.to change(Email, :count).by(1)
    end

    # The dirty gate is a *cascade* rule. Saving a component yourself means you
    # want the row, whatever it holds.
    it "does not apply the dirty gate to a component saved directly" do
      user = User.create!

      expect { Name.create!(entity: user) }.to change(Name, :count).by(1)
    end
  end
end
