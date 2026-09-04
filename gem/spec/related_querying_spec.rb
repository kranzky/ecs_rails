# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0013: relationship-name query & preload sugar — with_related /
# without_related / includes_related, decided by ADR-0014.
#
# These wrap the component verbs (with_component / without_component /
# includes_components, RFC-0010/0011) with the relationship's declared name, so
# the shared `Relationship` component and its slot never appear in app code. The
# tests are the RFC's contract tests, ADAPTED to the gem's fixtures
# (spec/support/models.rb):
#
#   - Post declares `relates_to :author, User` — rows in `relationships` under
#     slot "author" (ADR-0017).
#   - Comment ALSO declares `relates_to :author, User` — the SAME table and the
#     SAME slot, so the no-cross-entity-leak test is real and load-bearing: only
#     the entity-model scope `with_component` applies keeps them apart
#     (ADR-0014, amended).
#   - Membership is a join entity relating :user and :team.
RSpec.describe "relationship-name query DSL" do
  describe "with_related" do
    it "filters by target entity" do
      post = Post.create!
      ada = User.create!
      post.author = ada
      post.save!

      other = Post.create!
      other.author = User.create!
      other.save!

      expect(Post.with_related(:author, ada)).to contain_exactly(post)
    end

    it "accepts a bare id" do
      post = Post.create!
      ada = User.create!
      post.author = ada
      post.save!

      expect(Post.with_related(:author, ada.id)).to contain_exactly(post)
    end

    it "with no target, filters to entities that have the relationship set" do
      set = Post.create!
      set.author = User.create!
      set.save!
      Post.create! # unset — no backing row

      expect(Post.with_related(:author)).to contain_exactly(set)
    end

    # THE proof it is exact sugar (ADR-0014): with_related compiles to the very
    # same SQL as the hand-written, slot-scoped with_component on Relationship.
    it "is sugar over with_component on Relationship, slot-scoped (identical SQL)" do
      ada = User.create!

      expect(Post.with_related(:author, ada).to_sql)
        .to eq(Post.with_component(Relationship, prefix: :author, target_id: ada.id).to_sql)
    end

    it "with no target, equals with_component on Relationship in the slot" do
      expect(Post.with_related(:author).to_sql)
        .to eq(Post.with_component(Relationship, prefix: :author).to_sql)
    end

    it "narrows by slot, so another relationship to the same target does not match" do
      # A Membership's :user and :team both live in the one table; :user rows
      # must not answer a :team query.
      user = User.create!
      team = Team.create!
      membership = Membership.create!(user: user, team: team)
      other = Membership.create!(user: user)

      aggregate_failures do
        expect(Membership.with_related(:team, team)).to contain_exactly(membership)
        expect(Membership.with_related(:user, user)).to contain_exactly(membership, other)
      end
    end

    # No cross-entity leak (inherits ADR-0011 scoping): a Comment relating :author
    # to the same user must not appear in Post.with_related(:author, ...).
    it "does not leak across entity types" do
      ada = User.create!

      post = Post.create!
      post.author = ada
      post.save!

      comment = Comment.create!
      comment.author = ada
      comment.save!

      aggregate_failures do
        expect(Post.with_related(:author, ada)).to contain_exactly(post)
        expect(Comment.with_related(:author, ada)).to contain_exactly(comment)
      end
    end

    it "raises a named error for an unknown relationship" do
      expect { Post.with_related(:nope, User.create!) }
        .to raise_error(EcsRails::InvalidRelationship, /nope/)
    end

    it "raises InvalidRelationship, which is an InvalidComponent" do
      expect { Post.with_related(:nope) }
        .to raise_error(EcsRails::InvalidComponent)
    end

    it "names the entity's declared relationships in the error" do
      # Membership relates :user and :team — the message should list them.
      expect { Membership.with_related(:nope) }
        .to raise_error(EcsRails::InvalidRelationship, /:user.*:team|:team.*:user/)
    end

    it "chains with ordinary ActiveRecord" do
      expect(Post.with_related(:author).order(created_at: :desc))
        .to be_a ActiveRecord::Relation
    end

    it "is available on a relation, not just the class" do
      post = Post.create!
      ada = User.create!
      post.author = ada
      post.save!

      # Runs through the relation, keeping the scope built up before it.
      expect(Post.all.where.not(id: nil).with_related(:author, ada))
        .to contain_exactly(post)
    end

    it "resolves an inherited relationship on a subclass" do
      subclass = stub_const("SpecialPost", Class.new(Post))
      special = subclass.create!
      ada = User.create!
      special.author = ada
      special.save!

      # SpecialPost declares no relationship of its own; it inherits Post's.
      expect(subclass.with_related(:author, ada)).to contain_exactly(special)
    end
  end

  describe "without_related" do
    it "returns entities with no backing row" do
      set = Post.create!
      set.author = User.create!
      set.save!
      unset = Post.create!

      expect(Post.without_related(:author)).to contain_exactly(unset)
    end

    it "is sugar over without_component on Relationship, slot-scoped" do
      expect(Post.without_related(:author).to_sql)
        .to eq(Post.without_component(Relationship, prefix: :author).to_sql)
    end

    it "is slot-scoped, so a row in another slot does not count as set" do
      membership = Membership.create!(user: User.create!)

      expect(Membership.without_related(:team)).to contain_exactly(membership)
      expect(Membership.without_related(:user)).to be_empty
    end

    it "raises a named error for an unknown relationship" do
      expect { Post.without_related(:nope) }
        .to raise_error(EcsRails::InvalidRelationship, /nope/)
    end
  end

  describe "includes_related" do
    # The sql.active_record counter the rest of the suite uses (see
    # spec/preloading_spec.rb): SCHEMA / TRANSACTION / cached never count.
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

    it "preloads the relationship so the target costs no extra query" do
      3.times do
        p = Post.create!
        p.author = User.create!
        p.save!
      end

      rel = Post.all.includes_related(:author)
      # posts + relationship rows + targets (the User entities) = 3, NOT
      # 1 + one row + one target per post (the N+1 the demo hit).
      expect { rel.each { |p| p.author } }.to issue_queries(3)
    end

    it "issues N+1 without preloading (the baseline)" do
      3.times do
        p = Post.create!
        p.author = User.create!
        p.save!
      end

      # posts + (backing + target) per post = 1 + 3*2 = 7.
      expect { Post.all.each { |p| p.author } }.to issue_queries(7)
    end

    it "preloads more than one relationship at once" do
      2.times do
        m = Membership.create!
        m.user = User.create!
        m.team = Team.create!
        m.save!
      end

      rel = Membership.all.includes_related(:user, :team)
      # memberships + user rows + user targets + team rows + team targets. Two
      # slot-scoped has_ones over one table are still two preload queries.
      expect { rel.each { |m| [m.user, m.team] } }.to issue_queries(5)
    end

    it "yields the concrete target subclass through the preload (ADR-0008)" do
      post = Post.create!(author: User.create!)

      loaded = Post.all.includes_related(:author).find(post.id)
      expect(loaded.author).to be_an_instance_of User
    end

    it "raises for an unknown relationship" do
      expect { Post.includes_related(:nope) }
        .to raise_error(EcsRails::InvalidRelationship, /nope/)
    end

    it "is chainable and returns a relation" do
      expect(Post.all.includes_related(:author)).to be_a ActiveRecord::Relation
    end

    it "keeps the entity-model scope (builds from all)" do
      post = Post.create!
      post.author = User.create!
      post.save!
      user = User.create!

      result = Post.where.not(id: nil).includes_related(:author)
      aggregate_failures do
        expect(result).to contain_exactly(post)
        expect(result).not_to include(user)
      end
    end
  end

  # Reload safety (RFC-0013): metadata is stored by NAME and resolved via
  # constantize on read, on a per-class ivar that a reloaded (fresh) class body
  # repopulates from empty. So after a simulated reload — a new class object under
  # the same constant, re-running relates_to — with_related resolves through the
  # NEW class's metadata. Mirrors spec/relationships_spec.rb's reload scenario.
  describe "surviving a Rails development-mode class reload" do
    def reload!
      EcsRails.registry.clear!
      stub_const("Reloadable", Class.new(ApplicationEntity))
    end

    before { EcsRails.registry.clear! }

    it "resolves with_related through the post-reload class" do
      original = stub_const("Reloadable", Class.new(ApplicationEntity))
      original.relates_to(:author, User)

      reloaded = reload!
      reloaded.relates_to(:author, User)

      ada = User.create!
      entity = reloaded.create!
      entity.author = ada
      entity.save!

      aggregate_failures do
        expect(reloaded).not_to equal original
        expect(reloaded.relationship_meta(:author).target_class).to eq User
        expect(reloaded.relationship_meta(:author).slot).to eq "author"
        # And the query works end to end through the reloaded class.
        expect(reloaded.with_related(:author, ada)).to contain_exactly(entity)
      end
    end
  end
end
