# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0010: the component query DSL — with_component / without_component,
# decided by ADR-0011.
#
# These are the RFC's contract tests, ADAPTED to the gem's fixtures. The RFC's
# examples use the demo's models (PublishState on Post+Group, a Likes component),
# which do not exist here. The gem's fixtures give the same shapes:
#
#   - Name is declared on BOTH User and Post (spec/support/models.rb), so it is
#     the shared component that must not leak across entity types — the exact
#     bug the demo's hand-rolled query risked (ADR-0011).
#   - Email (on User) has `address` (string) and `verified` (boolean), for the
#     attribute-condition and injection-safety tests.
#   - Post declares Name and Avatar, for the chain/AND and NOT EXISTS tests.
#   - PublishState is declared on NO entity but owns a `state` column, so it
#     exercises "querying a component the entity does not declare is a valid,
#     always-empty query, not an error" (RFC-0010).
RSpec.describe "component query DSL" do
  describe "with_component" do
    it "returns entities that have the component row" do
      p1 = Post.create!
      p1.name.first = "has-a-name"
      p1.save!
      Post.create! # no name row

      expect(Post.with_component(Name)).to contain_exactly(p1)
    end

    it "filters by a string attribute condition" do
      match = User.create!
      match.email.address = "a@b.com"
      match.save!
      other = User.create!
      other.email.address = "c@d.com"
      other.save!

      expect(User.with_component(Email, address: "a@b.com")).to contain_exactly(match)
    end

    it "filters by a boolean attribute condition" do
      verified = User.create!
      verified.email.address = "v@b.com"
      verified.email.verified = true
      verified.save!
      plain = User.create!
      plain.email.address = "p@b.com"
      plain.save!

      expect(User.with_component(Email, verified: true)).to contain_exactly(verified)
    end

    # THE CRUX (ADR-0011): a component table is blind to entity type. Name has
    # rows for both a User and a Post; Post.with_component(Name) must return ONLY
    # the post. The entity-model scope (model = 'posts') is not added by the DSL
    # — it falls out of the method running on Post's own default-scoped relation.
    it "does not leak a shared component across entity types" do
      user = User.create!
      user.name.first = "a-user"
      user.save!
      post = Post.create!
      post.name.first = "a-post"
      post.save!

      expect(Post.with_component(Name)).to contain_exactly(post)
      expect(Post.with_component(Name)).not_to include(user)
      # And symmetrically, from the other side.
      expect(User.with_component(Name)).to contain_exactly(user)
      expect(User.with_component(Name)).not_to include(post)
    end

    it "compiles to a correlated EXISTS, not a join (no duplicate rows)" do
      post = Post.create!
      post.name.first = "x"
      post.save!

      sql = Post.with_component(Name).to_sql
      expect(sql).to match(/EXISTS/i)
      # Correlated on entity_id against the OUTER entities table (ADR-0011).
      expect(sql).to match(/"names"\."entity_id"\s*=\s*"entities"\."id"/i)
      # EXISTS matches once — no duplicate rows.
      expect(Post.with_component(Name).count).to eq 1
    end

    it "chains and ANDs multiple with_component calls" do
      both = Post.create!
      both.name.first = "n"
      both.avatar.url = "http://img"
      both.save!
      name_only = Post.create!
      name_only.name.first = "n"
      name_only.save!

      result = Post.with_component(Name).with_component(Avatar)
      expect(result).to contain_exactly(both)
      expect(result).not_to include(name_only)
    end

    it "chains onto an ordinary relation and keeps the entity-model scope" do
      post = Post.create!
      post.name.first = "keep"
      post.save!
      user = User.create!
      user.name.first = "leak?"
      user.save!

      # AR delegates the class method to the relation; the default_scope on that
      # relation still contributes model = 'posts', so the user cannot leak in.
      result = Post.where.not(id: nil).with_component(Name)
      expect(result).to contain_exactly(post)
      expect(result).not_to include(user)
    end

    it "composes with ordinary AR (order/limit) and returns a relation" do
      expect(Post.with_component(Name).order(created_at: :desc))
        .to be_a ActiveRecord::Relation
      expect(Post.with_component(Name).order(created_at: :desc).limit(5))
        .to be_a ActiveRecord::Relation
    end

    it "is a valid, always-empty query for a component the entity does not declare" do
      Post.create!
      # PublishState is declared on no entity, and no rows exist: not an error,
      # just empty (RFC-0010).
      expect(Post.with_component(PublishState)).to be_empty
      expect { Post.with_component(PublishState) }.not_to raise_error
    end

    it "queries a component the entity does not declare when a row exists" do
      post = Post.create!
      PublishState.create!(entity_id: post.id, state: "published")

      expect(Post.with_component(PublishState, state: "published")).to contain_exactly(post)
    end

    it "rejects a non-component" do
      expect { Post.with_component(String) }.to raise_error(EcsRails::InvalidComponent)
    end

    it "rejects an abstract component (owns no table)" do
      expect { Post.with_component(ApplicationComponent) }
        .to raise_error(EcsRails::InvalidComponent)
    end

    # SQL injection: a condition value is data, never SQL. AR sanitises it because
    # the subquery is built from component_class.where(conditions) (ADR-0011).
    it "sanitises condition values (no SQL injection)" do
      # Contains an "@" so it passes Email's format validation, and a quote plus
      # a statement terminator so an unsanitised build would execute it.
      nasty = "a@b'; DROP TABLE emails; --"
      user = User.create!
      user.email.address = nasty
      user.save!

      # The value is matched as a literal, so the crafted string finds its own row
      # and nothing is executed. The emails table survives.
      expect { User.with_component(Email, address: nasty) }.not_to raise_error
      expect(User.with_component(Email, address: nasty)).to contain_exactly(user)
      expect(Email.count).to be >= 1 # table intact
    end
  end

  describe "without_component" do
    it "returns entities with no row for the component" do
      with = Post.create!
      with.name.first = "present"
      with.save!
      without = Post.create!

      expect(Post.without_component(Name)).to contain_exactly(without)
    end

    it "compiles to NOT EXISTS" do
      expect(Post.without_component(Avatar).to_sql).to match(/NOT\s+EXISTS/i)
    end

    it "correlates the NOT EXISTS on entity_id" do
      expect(Post.without_component(Avatar).to_sql)
        .to match(/"avatars"\."entity_id"\s*=\s*"entities"\."id"/i)
    end

    it "treats a virtual (unpersisted) component as absent" do
      post = Post.create!
      post.name # read it — a virtual Name, still no row (RFC-0006)

      expect(Post.without_component(Name)).to include(post)
    end

    it "does not leak a shared component across entity types" do
      # A post with no Name row, and a user WITH a Name row. Post.without_component
      # must still return the post — the user's name row is invisible here because
      # the default scope pins model = 'posts'.
      post = Post.create!
      user = User.create!
      user.name.first = "a-user"
      user.save!

      expect(Post.without_component(Name)).to contain_exactly(post)
      expect(Post.without_component(Name)).not_to include(user)
    end

    it "rejects a non-component" do
      expect { Post.without_component(String) }.to raise_error(EcsRails::InvalidComponent)
    end
  end
end
