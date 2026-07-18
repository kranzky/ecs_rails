# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0009: component presence — add / has? / remove / <reader>?.
#
# Surfaced by the demo (ADR-0009): a marker component (Moderator) carries no
# state, so it is never `ecs_dirty?` and the RFC-0006 save cascade never writes
# it. `user.moderator; user.save!` silently persists nothing. Presence has to be
# its own verb — set it, ask it, undo it — and that verb is useful for every
# component, not just empty ones.
#
# "Free unless you use them" (RFC-0006) is a claim about SQL, so the side-effect
# examples assert the *absence* of statements: `has?` must be a bare existence
# check, never a load or an insert.
RSpec.describe "component presence" do
  # Statements issued while the block runs. Same helper as the sibling specs;
  # here it proves has? issues no INSERT.
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
  # Copied verbatim from RFC-0009. These are the contract.
  describe "the RFC's contract" do
    it "adds a marker that the save cascade never would" do
      user = User.create!
      expect { user.add(Moderator) }.to change { Moderator.where(entity_id: user.id).count }.by(1)
      expect(user.moderator?).to be true
      expect(user.has?(Moderator)).to be true
    end

    it "is idempotent" do
      user = User.create!
      user.add(Moderator)
      expect { user.add(Moderator) }.not_to change(Moderator, :count)
    end

    it "removes a marker and resets to virtual" do
      user = User.create!
      user.add(Moderator)
      user.remove(Moderator)
      expect(user.moderator?).to be false
      expect(user.moderator).not_to be_persisted
    end

    it "remove is idempotent when absent" do
      user = User.create!
      expect { user.remove(Moderator) }.not_to raise_error
    end

    it "validates on add" do
      user = User.create!
      expect { user.add(Email) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "rejects a component the entity does not declare" do
      user = User.create!
      expect { user.add(PublishState) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "has? does not materialise or dirty an untouched component" do
      user = User.create!
      expect { user.has?(Email) }.not_to change(Email, :count)
      # and issues no INSERT; a bare existence check
    end

    it "the predicate equals has?" do
      user = User.create!
      user.add(Moderator)
      expect(user.moderator?).to eq user.has?(Moderator)
    end
  end

  # --- add -------------------------------------------------------------------

  describe "#add" do
    it "returns the persisted instance" do
      user = User.create!
      moderator = user.add(Moderator)

      expect(moderator).to be_a Moderator
      expect(moderator).to be_persisted
    end

    it "persists immediately, not on the next save" do
      user = User.create!
      user.add(Moderator)

      # No save! call between the add and the assertion.
      expect(Moderator.where(entity_id: user.id)).to exist
    end

    it "returns the same instance on a second, idempotent add" do
      user = User.create!
      first = user.add(Moderator)

      expect(user.add(Moderator)).to equal first
    end

    it "issues no second INSERT on a second add" do
      user = User.create!
      user.add(Moderator)

      expect(capture_sql { user.add(Moderator) }.grep(/INSERT INTO "moderators"/)).to be_empty
    end

    it "adopts a row that already exists, without inserting a second" do
      user = User.create!
      Moderator.create!(entity_id: user.id)

      # The unique entity_id index (ADR-0005) would raise on a second INSERT.
      expect { user.add(Moderator) }.not_to change(Moderator, :count)
      expect(user.add(Moderator)).to be_persisted
    end

    it "raises InvalidComponent for a component the entity does not declare" do
      user = User.create!

      expect { user.add(PublishState) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "raises InvalidComponent for something that is not a component at all" do
      user = User.create!

      expect { user.add(String) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "persists a stateful component once its validations are met" do
      user = User.create!
      user.email.address = "a@b.com"

      expect { user.add(Email) }.to change(Email, :count).by(1)
    end
  end

  # --- has? and the memo (RFC-0006) ------------------------------------------
  #
  # THE side-effect contract. has? must consult the memo first, and for an
  # untouched component fall to a bare existence check — a SELECT, never a load
  # or an insert, and it must not dirty anything.
  describe "#has?" do
    it "is true when a row exists" do
      user = User.create!
      Moderator.create!(entity_id: user.id)

      expect(user.has?(Moderator)).to be true
    end

    it "is false when no row exists" do
      expect(User.create!.has?(Moderator)).to be false
    end

    it "issues no INSERT for an untouched component" do
      user = User.create!

      expect(capture_sql { user.has?(Email) }.grep(/INSERT/)).to be_empty
    end

    it "does not populate the memo with a dirty instance" do
      user = User.create!
      user.has?(Email)

      # If has? had loaded/built the component into the memo, the cascade would
      # find it. It must leave nothing dirty behind.
      expect(user.email).not_to be_ecs_dirty
      expect { user.save! }.not_to change(Email, :count)
    end

    it "answers from the memo, with no query, once a component is loaded and saved" do
      user = User.create!
      user.email.address = "a@b.com"
      user.save! # dirtied-and-saved this instance; memo holds the persisted row

      expect(capture_sql { user.has?(Email) }).to be_empty
      expect(user.has?(Email)).to be true
    end

    it "raises InvalidComponent for a component the entity does not declare" do
      user = User.create!

      expect { user.has?(PublishState) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "reflects a component dirtied and saved through the reader" do
      user = User.create!
      user.email.update!(address: "a@b.com")

      expect(user.has?(Email)).to be true
    end
  end

  # --- remove ----------------------------------------------------------------

  describe "#remove" do
    it "destroys the row when present" do
      user = User.create!
      user.add(Moderator)

      expect { user.remove(Moderator) }.to change(Moderator, :count).by(-1)
    end

    it "returns the entity" do
      user = User.create!
      user.add(Moderator)

      expect(user.remove(Moderator)).to equal user
    end

    it "resets the reader to a virtual instance, exactly like component.destroy" do
      user = User.create!
      user.add(Moderator)
      user.remove(Moderator)

      expect(user.moderator).to be_a Moderator
      expect(user.moderator).not_to be_persisted
    end

    it "is idempotent when the component is absent" do
      user = User.create!

      expect { user.remove(Moderator) }.not_to change(Moderator, :count)
      expect(user.remove(Moderator)).to equal user
    end

    it "removes a stateful component too" do
      user = User.create!
      user.email.update!(address: "a@b.com")

      expect { user.remove(Email) }.to change(Email, :count).by(-1)
      expect(user.email).not_to be_persisted
    end

    it "raises InvalidComponent for a component the entity does not declare" do
      user = User.create!

      expect { user.remove(PublishState) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "can be added again after removal" do
      user = User.create!
      user.add(Moderator)
      user.remove(Moderator)

      expect { user.add(Moderator) }.to change(Moderator, :count).by(1)
      expect(user.has?(Moderator)).to be true
    end
  end

  # --- the generated predicate -----------------------------------------------
  #
  # RFC-0009: `entity.<reader>?` is generated per component and equals
  # has?(ThatComponent).
  describe "the <reader>? predicate" do
    it "exists for a marker component" do
      expect(User.new).to respond_to :moderator?
    end

    it "exists for a stateful component" do
      expect(User.new).to respond_to :email?
    end

    it "equals has? for the same component" do
      user = User.create!
      user.email.update!(address: "a@b.com")

      expect(user.email?).to eq user.has?(Email)
    end

    it "is false for an absent component" do
      expect(User.create!.email?).to be false
    end

    it "is true for a present one" do
      user = User.create!
      user.add(Moderator)

      expect(user.moderator?).to be true
    end
  end

  # --- the marker round-trip -------------------------------------------------
  #
  # The demo's Moderator is zero-attribute. Prove the whole cycle a marker needs:
  # add → has? → the row exists → remove → gone. This is the case the lazy save
  # cascade can never serve, and the reason RFC-0009 exists.
  describe "a zero-attribute marker round-trip" do
    it "adds, confirms, and removes" do
      user = User.create!

      expect(user.moderator?).to be false

      user.add(Moderator)
      expect(user.moderator?).to be true
      expect(user.has?(Moderator)).to be true
      expect(Moderator.where(entity_id: user.id)).to exist

      user.remove(Moderator)
      expect(user.moderator?).to be false
      expect(Moderator.where(entity_id: user.id)).not_to exist
    end

    it "keeps the memo coherent: the reader returns the added row without a fresh query" do
      user = User.create!
      added = user.add(Moderator)

      # add populated the memo (RFC-0006), so the reader answers from it.
      expect(capture_sql { user.moderator }).to be_empty
      expect(user.moderator).to equal added
      expect(user.moderator).to be_persisted
    end

    it "survives the natural marker path the demo tried first" do
      user = User.create!
      user.moderator  # the read that used to memoise a virtual, then...
      user.save!      # ...a save that persisted nothing.

      expect(user.moderator?).to be false # the friction the demo hit

      user.add(Moderator) # the fix
      expect(user.moderator?).to be true
    end
  end
end
