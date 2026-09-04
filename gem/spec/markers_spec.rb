# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0016: markers as slots of one Marker component, declared with
# `marker` — ADR-0018 §4, amending ADR-0009's rejection of the keyword.
#
#   class User < ApplicationEntity
#     marker :moderator
#   end
#
#   user.add(:moderator); user.moderator?; user.remove(:moderator)
#
# Presence semantics are exactly RFC-0009's — a row is the meaning, `add`
# writes it now, the save cascade never would. What is new is the storage (one
# `markers` table, slot = marker name) and the sugar that keeps the bare
# `moderator?` prefixing would otherwise turn into `moderator_marker?`.
#
# The `Moderator` fixture — a zero-attribute component on its own table — stays
# in spec/support and is still exercised by presence_spec: ADR-0009's original
# shape keeps working; `marker` is the shape that needs no migration.
RSpec.describe "markers" do
  before { EcsRails.registry.clear! }

  def declare_user
    stub_const("Member", Class.new(ApplicationEntity))
    Member.component Email
    Member.marker :moderator
    Member.marker :administrator
    Member
  end

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

  # --- the contract ------------------------------------------------------------
  describe "the contract" do
    it "adds a marker by name and answers the bare predicate" do
      user = declare_user.create!
      user.add(:moderator)

      expect(user.moderator?).to be true
      expect(user.administrator?).to be false
    end

    it "removes it by name" do
      user = declare_user.create!
      user.add(:moderator)
      user.remove(:moderator)

      expect(user.moderator?).to be false
    end

    it "answers has? by name" do
      user = declare_user.create!
      user.add(:administrator)

      expect(user.has?(:administrator)).to be true
      expect(user.has?(:moderator)).to be false
    end

    it "is a row in the shared markers table under the marker's slot" do
      user = declare_user.create!
      user.add(:moderator)

      expect(Marker.where(entity_id: user.id).pluck(:slot)).to eq ["moderator"]
    end

    it "is never written by the save cascade, only by add" do
      user = declare_user.create!
      user.moderator_marker # read the virtual
      user.save!

      expect(Marker.where(entity_id: user.id)).to be_empty
    end

    it "still works through the component form" do
      user = declare_user.create!
      user.add(Marker, prefix: :moderator)

      expect(user.moderator?).to be true
      expect(user.has?(Marker, prefix: :moderator)).to be true
      user.remove(Marker, prefix: :moderator)
      expect(user.moderator?).to be false
    end

    it "is idempotent" do
      user = declare_user.create!
      user.add(:moderator)
      user.add(:moderator)
      user.remove(:administrator)

      expect(Marker.where(entity_id: user.id).count).to eq 1
    end
  end

  # --- what `marker` declares ------------------------------------------------------
  describe "the declaration" do
    it "is component Marker in a slot named for the marker, undelegated" do
      declaration = declare_user.declaration_for(Marker, prefix: :moderator)

      aggregate_failures do
        expect(declaration).not_to be_nil
        expect(declaration.slot).to eq "moderator"
        expect(declaration.reader_name).to eq :moderator_marker
        expect(declaration.options).to eq(delegate: false)
      end
    end

    it "generates the bare predicate and writer, plus the slot reader" do
      user = declare_user.new

      expect(user).to respond_to(:moderator?, :moderator=, :moderator_marker, :moderator_marker?)
      expect(user).not_to respond_to(:moderator)
    end

    it "lists the marker names, ancestry included" do
      declare_user
      stub_const("Staff", Class.new(Member))
      Staff.marker :owner

      expect(Member.marker_names).to eq %i[moderator administrator]
      expect(Staff.marker_names).to eq %i[moderator administrator owner]
      expect(Staff.marker?(:moderator)).to be true
      expect(Member.marker?(:owner)).to be false
    end

    it "lists Marker once among the components" do
      expect(declare_user.components).to eq [Email, Marker]
    end

    it "rejects a name that is not a slot label" do
      klass = stub_const("Bad", Class.new(ApplicationEntity))

      expect { klass.marker :"Super User" }.to raise_error(ArgumentError, /not a valid slot label/)
    end

    it "treats the same marker twice as a duplicate" do
      klass = declare_user

      expect { klass.marker :moderator }.to raise_error(EcsRails::DuplicateComponent, /moderator/)
    end

    it "explains what to do when the app has no Marker component" do
      EcsRails.config.marker_class_name = "NoSuchMarker"
      klass = stub_const("Lonely", Class.new(ApplicationEntity))

      expect { klass.marker :moderator }.to raise_error(NameError, /ecs_rails:install.*marker_class_name/m)
    ensure
      EcsRails.config.marker_class_name = "Marker"
    end
  end

  # --- the Boolean writer ------------------------------------------------------------
  describe "the writer" do
    it "adds on true and removes on false" do
      user = declare_user.create!
      user.moderator = true
      expect(user.moderator?).to be true

      user.moderator = false
      expect(user.moderator?).to be false
    end

    it "casts form values the way ActiveModel does" do
      user = declare_user.create!
      user.moderator = "1"
      expect(user.moderator?).to be true

      user.moderator = "0"
      expect(user.moderator?).to be false
    end

    it "routes through flat mass assignment on a persisted entity" do
      user = declare_user.create!
      user.update!(moderator: true, email_address: "a@b.com")

      expect(user.reload.moderator?).to be true
      expect(user.email_address).to eq "a@b.com"
    end
  end

  # --- collisions (ADR-0004) -----------------------------------------------------------
  describe "collisions" do
    it "refuses a marker whose predicate is a component's presence predicate" do
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.component Email

      expect { klass.marker :email }.to raise_error(EcsRails::DelegationConflict, /#email\?/)
    end

    it "refuses a marker whose writer is a delegated writer" do
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.component Email, prefix: false

      expect { klass.marker :verified }.to raise_error(EcsRails::DelegationConflict, /#verified=/)
    end

    it "refuses a later bare component that would delegate over a marker's writer" do
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.marker :verified

      expect { klass.component Email, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /#verified=.*marker :verified/m)
    end

    it "refuses a relationship named like a marker" do
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.marker :author

      # relates_to :author would define author=; the marker owns it.
      expect { klass.relates_to :author, User }.to raise_error(EcsRails::DelegationConflict)
    end
  end

  # --- presence with unknown names ------------------------------------------------------
  describe "an undeclared marker" do
    it "raises InvalidComponent naming the declared markers" do
      user = declare_user.create!

      expect { user.add(:owner) }
        .to raise_error(EcsRails::InvalidComponent, /:owner is not a marker of Member.*:moderator, :administrator/m)
      expect { user.has?(:owner) }.to raise_error(EcsRails::InvalidComponent)
      expect { user.remove(:owner) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "rejects a prefix alongside a marker name" do
      user = declare_user.create!

      expect { user.add(:moderator, prefix: :x) }.to raise_error(ArgumentError, /prefix/)
    end
  end

  # --- querying --------------------------------------------------------------------------
  describe "querying" do
    it "filters by marker with with_marker / without_marker" do
      klass = declare_user
      mod = klass.create!
      mod.add(:moderator)
      plain = klass.create!

      expect(klass.with_marker(:moderator)).to contain_exactly(mod)
      expect(klass.without_marker(:moderator)).to contain_exactly(plain)
    end

    it "is sugar over with_component on Marker, slot-scoped" do
      klass = declare_user

      expect(klass.with_marker(:moderator).to_sql).to eq klass.with_component(Marker, prefix: :moderator).to_sql
      expect(klass.without_marker(:moderator).to_sql).to eq klass.without_component(Marker, prefix: :moderator).to_sql
    end

    it "raises for an undeclared marker" do
      expect { declare_user.with_marker(:owner) }.to raise_error(EcsRails::InvalidComponent, /:owner/)
    end

    it "does not leak across entity types sharing a marker name" do
      declare_user
      stub_const("Bot", Class.new(ApplicationEntity))
      Bot.marker :moderator
      user = Member.create!
      user.add(:moderator)
      bot = Bot.create!
      bot.add(:moderator)

      expect(Member.with_marker(:moderator)).to contain_exactly(user)
      expect(Bot.with_marker(:moderator)).to contain_exactly(bot)
    end
  end

  # --- preloading ------------------------------------------------------------------------
  describe "preloading" do
    it "preloads every marker slot with includes_components(Marker), so the predicates cost nothing" do
      klass = declare_user
      2.times { klass.create!.add(:moderator) }

      loaded = klass.all.includes_components(Marker).to_a
      sql = capture_sql { loaded.each { |u| [u.moderator?, u.administrator?] } }

      expect(sql).to be_empty
    end
  end

  # --- reload ------------------------------------------------------------------------------
  describe "surviving a Rails development-mode class reload" do
    it "re-declares without raising and keeps working" do
      declare_user
      EcsRails.registry.clear!
      reloaded = stub_const("Member", Class.new(ApplicationEntity))

      expect { reloaded.marker :moderator }.not_to raise_error
      user = reloaded.create!
      user.add(:moderator)
      expect(user.moderator?).to be true
    end
  end
end
