# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0011: component preloading — includes_components, decided by
# ADR-0012.
#
# Half of this RFC's job is REGRESSION: ADR-0012's whole premise is that
# ActiveRecord's native `preload` already works with the lazy reader (each
# component is a has_one, and RFC-0006's reader calls `super`). These tests pin
# that native path — batched-plus-virtual — so a future change to the lazy reader
# that broke preload would fail loudly, rather than silently reintroducing the
# N+1 the demo hit.
#
# ## Fixture note (a departure from the RFC's literal examples)
#
# The RFC's "all declared components" example reads `u.avatar.url` on a User, but
# in the gem fixtures (spec/support/models.rb) User is composed from Name, Email,
# Group and Moderator — it does NOT declare Avatar (that is Post's). Reading
# `u.avatar` on a User would be a NoMethodError. So the tests below read User's
# ACTUAL declared components. Same shape, real fixtures.
RSpec.describe "component preloading" do
  # Statements issued while the block runs, filtered the way the rest of the
  # suite filters (spec/lazy_spec.rb, spec/querying_spec.rb): SCHEMA and cached
  # queries never count, and TRANSACTION statements (the BEGIN/SAVEPOINT the
  # suite's per-example transaction emits) are excluded too, so counts are stable
  # regardless of how ActiveRecord frames the reads.
  def count_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]

      statements << payload[:sql]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # RFC-0011's `issue_queries(n)` matcher — a thin sql.active_record counter over
  # #count_sql. Block-based, so it reads `expect { ... }.to issue_queries(n)`.
  matcher :issue_queries do |expected|
    supports_block_expectations

    match do |block|
      @statements = count_sql(&block)
      @statements.size == expected
    end

    failure_message do
      "expected the block to issue #{expected} queries, but it issued " \
        "#{@statements.size}:\n  #{@statements.join("\n  ")}"
    end
  end

  describe "includes_components" do
    # --- REGRESSION: the native path this wraps must keep working ------------
    #
    # This is the most important test in the file. `includes_components` is only
    # a wrapper; if native `preload` ever stopped batching, or stopped feeding
    # the lazy reader so that a missing row read as nil instead of a virtual,
    # the wrapper would inherit the break. Pin both here.
    it "native preload batches and still returns virtuals" do
      3.times { |i| u = User.create!; u.name.first = "U#{i}"; u.save! }
      User.create! # no name row

      # Batched: users + names = 2, NOT 1 + 4 (the N+1).
      expect { User.all.preload(:name).each { |u| u.name.first } }
        .to issue_queries(2)

      # And the user with no name row still reads as a VIRTUAL Name through the
      # lazy reader — a Name instance, unpersisted, never nil — after preload.
      novirtual = User.all.preload(:name).detect { |u| u.name.first.nil? }
      expect(novirtual.name).to be_a(Name)
      expect(novirtual.name).not_to be_persisted
    end

    # The N+1 baseline, so the batching claim above is anchored to a real number:
    # 4 users, one SELECT each for name = 5 queries without preload.
    it "issues N+1 without preloading (the baseline the demo hit)" do
      4.times { |i| u = User.create!; u.name.first = "U#{i}"; u.save! }

      expect { User.all.each { |u| u.name.first } }.to issue_queries(5)
    end

    # --- the wrapper --------------------------------------------------------
    it "preloads all declared components with no args" do
      2.times do |i|
        u = User.create!
        u.name.first = "U#{i}"
        u.email.address = "e#{i}@x.com"
        u.save!
      end

      rel = User.all.includes_components
      # users + one query per declared component (Name, Email, Group, Moderator).
      # Reading each component — including the two with no row (Group, Moderator),
      # which the lazy reader turns into virtuals — issues nothing further.
      expect do
        rel.each { |u| [u.name.first, u.email.address, u.group.description, u.moderator] }
      end.to issue_queries(1 + User.components.size)
    end

    it "preloads a named subset" do
      2.times do |i|
        u = User.create!
        u.name.first = "U#{i}"
        u.email.address = "e#{i}@x.com"
        u.save!
      end

      expect do
        User.all.includes_components(Name, Email).each { |u| [u.name.first, u.email.address] }
      end.to issue_queries(3) # users + names + emails
    end

    it "does not issue a query when reading a preloaded component" do
      u = User.create!
      u.name.first = "Ada"
      u.save!

      loaded = User.all.includes_components(Name).to_a
      expect { loaded.each { |x| x.name.first } }.to issue_queries(0)
    end

    it "rejects a component the entity does not declare" do
      # PublishState is a concrete component declared on NO entity in the fixtures.
      expect { User.includes_components(PublishState) }
        .to raise_error(EcsRails::InvalidComponent, /PublishState/)
    end

    it "rejects a real component declared on a different entity" do
      # Avatar is a genuine component, but declared on Post, not User.
      expect { User.includes_components(Avatar) }
        .to raise_error(EcsRails::InvalidComponent, /Avatar/)
    end

    it "rejects a non-component" do
      expect { User.includes_components(String) }
        .to raise_error(EcsRails::InvalidComponent)
    end

    it "composes with with_component" do
      u = User.create!
      u.name.first = "Ada"
      u.email.address = "a@b.com"
      u.save!

      expect do
        User.with_component(Name).includes_components(Name, Email)
            .each { |x| [x.name.first, x.email.address] }
      end.to issue_queries(3) # users (with EXISTS) + names + emails
    end

    it "composes with where/order and keeps the entity-model scope" do
      post = Post.create!
      post.name.first = "keep"
      post.save!
      user = User.create!
      user.name.first = "leak?"
      user.save!

      # includes_components on Post must not leak the User: it builds from `all`,
      # which carries Post's default scope (model = 'posts').
      result = Post.where.not(id: nil).order(created_at: :desc).includes_components(Name)
      expect(result).to contain_exactly(post)
      expect(result).not_to include(user)
    end

    it "is chainable and returns a relation" do
      expect(User.all.includes_components(Name)).to be_a ActiveRecord::Relation
      expect(User.all.includes_components).to be_a ActiveRecord::Relation
    end
  end
end
