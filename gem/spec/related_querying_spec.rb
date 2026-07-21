# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0013: relationship-name query & preload sugar — with_related /
# without_related / includes_related, decided by ADR-0014.
#
# These wrap the component verbs (with_component / without_component /
# includes_components, RFC-0010/0011) with the relationship's declared name, so
# the backing `*Relationship` class never appears in app code. The tests are the
# RFC's contract tests, ADAPTED to the gem's fixtures (spec/support/models.rb):
#
#   - Post declares `relates_to :author, User`, backed by `post_authors`.
#   - Comment ALSO declares `relates_to :author, User`, backed by
#     `comment_authors` — a distinct table, so the no-cross-entity-leak test is
#     real (the RFC uses Comment for exactly this).
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
    # same SQL as the hand-written with_component on the backing class.
    it "is sugar over with_component on the backing class (identical SQL)" do
      ada = User.create!

      expect(Post.with_related(:author, ada).to_sql)
        .to eq(Post.with_component(Post::AuthorRelationship, author_id: ada.id).to_sql)
    end

    it "with no target, equals with_component on the backing class" do
      expect(Post.with_related(:author).to_sql)
        .to eq(Post.with_component(Post::AuthorRelationship).to_sql)
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

    it "is sugar over without_component on the backing class" do
      expect(Post.without_related(:author).to_sql)
        .to eq(Post.without_component(Post::AuthorRelationship).to_sql)
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
      # posts + backings (post_authors) + targets (the User entities) = 3, NOT
      # 1 + one backing + one target per post (the N+1 the demo hit).
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
      # memberships + user backings + user targets + team backings + team targets.
      expect { rel.each { |m| [m.user, m.team] } }.to issue_queries(5)
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
  # the same constant, re-running relates_to — with_related resolves against the
  # NEW backing class. Mirrors spec/relationships_spec.rb's reload scenario, using
  # the `reloadable_authors` table.
  describe "surviving a Rails development-mode class reload" do
    def reload!
      EcsRails.registry.clear!
      stub_const("Reloadable", Class.new(ApplicationEntity))
    end

    before { EcsRails.registry.clear! }

    it "resolves with_related against the post-reload backing class" do
      original = stub_const("Reloadable", Class.new(ApplicationEntity))
      original.relates_to(:author, User)
      original_backing = original::AuthorRelationship

      reloaded = reload!
      reloaded.relates_to(:author, User)

      ada = User.create!
      entity = reloaded.create!
      entity.author = ada
      entity.save!

      aggregate_failures do
        # The metadata resolves to the NEW constant, not the orphaned original.
        expect(reloaded::AuthorRelationship).not_to equal original_backing
        expect(reloaded.relationship_meta(:author).backing_class)
          .to equal reloaded::AuthorRelationship
        # And the query works end to end through the reloaded class.
        expect(reloaded.with_related(:author, ada)).to contain_exactly(entity)
      end
    end
  end
end
