# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0012: the relationship DSL — `relates_to`, decided by ADR-0013.
#
# These are the RFC's contract tests, ADAPTED to the gem's fixtures. The RFC's
# examples use the demo's models (`Post relates_to :author, User`;
# `Membership relates_to :user/:group`). The gem's fixtures give the same shapes:
#
#   - Post declares `relates_to :author, User` (spec/support/models.rb), backed
#     by the `post_authors` table (spec/support/schema.rb).
#   - Membership is a join entity with `relates_to :user, User` and
#     `relates_to :team, Team` — the M2M pattern. The RFC's example relates to a
#     `Group`, but the gem's `Group` is a *component*, not an entity, so `Team`
#     stands in as the second target entity.
#
# Throwaway entity classes are stub_const'd (the registry keys by class name,
# RFC-0002, so an anonymous class cannot declare anything) and run against a
# cleared registry, restored centrally by spec_helper's after-hook.
RSpec.describe "the relationship DSL" do
  describe "reading and writing the target" do
    it "reads and writes the target" do
      post = Post.create!
      user = User.create!
      post.author = user
      post.save!

      expect(post.reload.author).to eq user
    end

    it "returns nil when unset (belongs_to, not a lazy component target)" do
      expect(Post.create!.author).to be_nil
    end

    it "exposes the writer through delegation" do
      expect(Post.new).to respond_to(:author, :author=)
    end
  end

  # ADR-0013 / RFC-0012 Open: the backing reader is `author_relationship`, NOT
  # `post_author_relationship`. See the note in EcsRails::Relationships for why a
  # naive derivation gets the doubled name and how the backing class pins its own
  # model_name to fix it.
  describe "the backing component" do
    it "is a real, named, concrete EcsRails::Component constant" do
      aggregate_failures do
        expect(Post::AuthorRelationship.name).to eq "Post::AuthorRelationship"
        expect(Post::AuthorRelationship).to be < EcsRails::Component
        expect(Post::AuthorRelationship.abstract_class?).to be_falsey
      end
    end

    it "reads the owner-scoped table name" do
      expect(Post::AuthorRelationship.table_name).to eq "post_authors"
    end

    it "exposes the backing reader as <relation>_relationship, not doubled up" do
      aggregate_failures do
        expect(Post.new).to respond_to(:author_relationship)
        expect(Post.new).not_to respond_to(:post_author_relationship)
      end
    end

    it "is the correct key for includes_components (has_one name agrees)" do
      post = Post.create!
      post.author = User.create!
      post.save!

      # No AssociationNotFoundError: the has_one name derived by the DSL matches
      # the backing reader, so the preload resolves.
      expect { Post.includes_components(Post::AuthorRelationship).to_a }.not_to raise_error
      expect(Post.includes_components(Post::AuthorRelationship)).to include(post)
    end

    it "defines a backing component that with_component sees" do
      post = Post.create!
      post.author = User.create!
      post.save!

      expect(Post.with_component(Post::AuthorRelationship)).to include(post)
    end
  end

  # THE load-bearing behaviour (ADR-0013): the target FK is NULLIFY, not cascade.
  # Asserted against the real database, not the migration text.
  describe "target deletion" do
    it "nullifies on target deletion, does not cascade to the owner" do
      post = Post.create!
      user = User.create!
      post.author = user
      post.save!

      user.destroy

      aggregate_failures do
        expect(Post.exists?(post.id)).to be true          # the owner survives
        expect(post.reload.author).to be_nil              # the link is nulled
        expect(Post::AuthorRelationship.where(entity_id: post.id).exists?).to be true # row survives, author_id NULL
      end
    end
  end

  describe "validation" do
    it "rejects a non-entity target" do
      expect { stub_const("Bad", Class.new(ApplicationEntity)).relates_to(:x, String) }
        .to raise_error(EcsRails::InvalidComponent) # InvalidRelationship is a subclass
    end

    it "raises the relationship-shaped InvalidRelationship specifically" do
      expect { stub_const("Bad", Class.new(ApplicationEntity)).relates_to(:x, String) }
        .to raise_error(EcsRails::InvalidRelationship, /relates_to :x/)
    end

    it "rejects a component dressed up as a target" do
      expect { stub_const("Bad", Class.new(ApplicationEntity)).relates_to(:x, Email) }
        .to raise_error(EcsRails::InvalidRelationship)
    end

    it "rejects an abstract entity target" do
      expect { stub_const("Bad", Class.new(ApplicationEntity)).relates_to(:x, ApplicationEntity) }
        .to raise_error(EcsRails::InvalidRelationship, /abstract/)
    end

    it "raises on a name collision, naming the relationship" do
      klass = stub_const("Dup", Class.new(ApplicationEntity))
      klass.relates_to :author, User

      expect { klass.relates_to :author, User }
        .to raise_error(EcsRails::DelegationConflict, /author/)
    end

    it "raises when the name clashes with an existing component reader" do
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.component Email

      expect { klass.relates_to :email, User }
        .to raise_error(EcsRails::DelegationConflict, /email/)
    end
  end

  # The join-entity case (ADR-0005): many-to-many as an entity with two
  # relationships. Fixture `Membership relates_to :user, User` + `:team, Team`.
  describe "a join entity with two relationships" do
    it "reads both targets cleanly" do
      membership = Membership.create!
      user = User.create!
      team = Team.create!
      membership.user = user
      membership.team = team
      membership.save!

      expect([membership.reload.user, membership.team]).to eq [user, team]
    end

    it "gives each relationship its own backing table" do
      aggregate_failures do
        expect(Membership::UserRelationship.table_name).to eq "membership_users"
        expect(Membership::TeamRelationship.table_name).to eq "membership_teams"
      end
    end

    it "does not cross-wire the two relationships" do
      membership = Membership.create!
      membership.user = User.create!
      membership.save!

      aggregate_failures do
        expect(membership.reload.user).to be_present
        expect(membership.team).to be_nil
      end
    end
  end

  # RFC-0012: subclasses inherit `relates_to` exactly as they inherit `component`.
  describe "inheritance" do
    it "inherits the relationship on a subclass" do
      subclass = stub_const("SpecialPost", Class.new(Post))
      special = subclass.create!
      user = User.create!
      special.author = user
      special.save!

      expect(special.reload.author).to eq user
    end

    it "lists the backing component among the subclass's components" do
      subclass = stub_const("SpecialPost", Class.new(Post))
      expect(subclass.components).to include(Post::AuthorRelationship)
    end
  end

  # Reload safety (RFC-0012): in development Rails drops the entity constant and
  # autoloads a brand-new class under the same name; the Railtie clears the
  # registry on to_prepare. So `relates_to` runs again, on a new class object,
  # against an empty registry — and must not raise DuplicateComponent, and must
  # still work. This is the subtle part: the backing class is *also* redefined
  # (a new nested const under the new entity), and the registry (keyed by name)
  # must resolve to the new constant.
  describe "surviving a Rails development-mode class reload" do
    def reload!
      EcsRails.registry.clear!
      stub_const("Reloadable", Class.new(ApplicationEntity))
    end

    before { EcsRails.registry.clear! }

    it "redeclares without raising DuplicateComponent" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).relates_to(:author, User)
      reloaded = reload!

      expect { reloaded.relates_to(:author, User) }.not_to raise_error
    end

    it "does not double-register the backing component" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).relates_to(:author, User)
      reload!.relates_to(:author, User)

      expect(EcsRails.registry.components_for(Reloadable).size).to eq 1
    end

    it "resolves the backing component to the new constant" do
      original = stub_const("Reloadable", Class.new(ApplicationEntity))
      original.relates_to(:author, User)
      original_backing = original::AuthorRelationship

      reloaded = reload!
      reloaded.relates_to(:author, User)

      aggregate_failures do
        expect(reloaded).not_to equal original
        expect(reloaded::AuthorRelationship).not_to equal original_backing
        # The registry holds the name; it resolves to the post-reload constant.
        expect(EcsRails.registry.components_for(Reloadable).first.component_class)
          .to equal reloaded::AuthorRelationship
      end
    end

    it "gives the reloaded class a working relationship" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).relates_to(:author, User)
      reloaded = reload!
      reloaded.relates_to(:author, User)

      entity = reloaded.create!
      user = User.create!
      entity.author = user
      entity.save!

      expect(entity.reload.author).to eq user
    end
  end
end
