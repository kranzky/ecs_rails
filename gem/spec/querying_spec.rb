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

  # --- beyond equality (RFC-0018) ---------------------------------------------
  #
  # The block runs as the component's own relation; positional args are
  # `where`-style. Both land inside the same correlated EXISTS, so the
  # entity-model scope and the no-duplicates property are unchanged.
  describe "with_component beyond equality" do
    def group_with_title(entity, title)
      entity.group.title = title
      entity.save!
      entity
    end

    it "filters with a block run on the component relation" do
      a = group_with_title(User.create!, "alpha")
      group_with_title(User.create!, "beta")

      expect(User.with_component(Group) { where("title < ?", "b") }).to contain_exactly(a)
    end

    it "accepts where.not and chained refinements in the block" do
      a = group_with_title(User.create!, "alpha")
      b = group_with_title(User.create!, "beta")

      expect(User.with_component(Group) { where.not(title: "alpha") }).to contain_exactly(b)
      expect(User.with_component(Group) { where.not(title: nil).where("title LIKE ?", "a%") }).to contain_exactly(a)
    end

    it "lets the block use the component's own scopes and class methods" do
      stub_const("TitledGroup", Class.new(Group) do
        self.table_name = "groups"
        scope :starting_with, ->(letter) { where("title LIKE ?", "#{letter}%") }
      end)
      a = group_with_title(User.create!, "alpha")
      group_with_title(User.create!, "beta")

      expect(User.with_component(TitledGroup) { starting_with("a") }).to contain_exactly(a)
    end

    it "accepts where-style positional conditions with binds" do
      a = group_with_title(User.create!, "alpha")
      group_with_title(User.create!, "beta")

      expect(User.with_component(Group, "title < ?", "b")).to contain_exactly(a)
      expect(User.with_component(Group, ["title < ?", "b"])).to contain_exactly(a)
    end

    it "combines equality, positional and block conditions" do
      a = group_with_title(User.create!, "alpha")
      a.group.update!(description: "d")
      group_with_title(User.create!, "alpha")

      expect(User.with_component(Group, "title LIKE ?", "a%", description: "d") { where.not(title: nil) })
        .to contain_exactly(a)
    end

    it "keeps the slot scoping under prefix: with a block" do
      stub_const("Customer", Class.new(ApplicationEntity))
      Customer.component Address
      Customer.component Address, prefix: :business
      c = Customer.create!(business_address_region: "WA", address_region: "NSW")
      Customer.create!(address_region: "WA")

      expect(Customer.with_component(Address, prefix: :business) { where(region: "WA") }).to contain_exactly(c)
    end

    it "still compiles to a single correlated EXISTS with the entity-model scope" do
      sql = User.with_component(Group) { where("title < ?", "b") }.to_sql

      aggregate_failures do
        expect(sql).to include('"entities"."model" = \'users\'')
        expect(sql.scan(/EXISTS/).size).to eq 1
        expect(sql).to match(/"groups"\."entity_id"\s*=\s*"entities"\."id"/i)
        expect(sql).to include("title < 'b'")
      end
    end

    it "sanitises positional binds" do
      group_with_title(User.create!, "alpha")

      expect(User.with_component(Group, "title = ?", "x'); DROP TABLE users; --")).to be_empty
    end

    it "rejects a block that does not return a relation of the component" do
      expect { User.with_component(Group) { 42 }.to_a }.to raise_error(ArgumentError, /must return a relation of Group/)
      expect { User.with_component(Group) { Email.all }.to_a }.to raise_error(ArgumentError, /relation of Group/)
    end
  end

  # --- ordering by a component column (RFC-0018) -------------------------------
  #
  # EXISTS cannot sort. order_by_component adds a correlated scalar subquery to
  # ORDER BY: no join, no alias, no duplicate rows, composes with everything.
  describe "order_by_component" do
    def user_titled(title)
      u = User.create!
      u.group.title = title if title
      u.save!
      u
    end

    it "orders ascending by a component column" do
      b = user_titled("beta")
      a = user_titled("alpha")

      expect(User.order_by_component(Group, :title)).to eq [a, b]
    end

    it "orders descending" do
      b = user_titled("beta")
      a = user_titled("alpha")

      expect(User.order_by_component(Group, :title, :desc)).to eq [b, a]
      expect(User.order_by_component(Group, :title, direction: :desc)).to eq [b, a]
    end

    it "puts entities without the row last, whatever the direction" do
      none = user_titled(nil)
      a = user_titled("alpha")
      b = user_titled("beta")

      expect(User.order_by_component(Group, :title)).to eq [a, b, none]
      expect(User.order_by_component(Group, :title, :desc)).to eq [b, a, none]
      expect(User.order_by_component(Group, :title, nulls: :first)).to eq [none, a, b]
    end

    it "defaults the column to the component's primary attribute" do
      stub_const("Article", Class.new(ApplicationEntity))
      Article.component Counter, prefix: :likes
      low = Article.create!(likes: 1)
      high = Article.create!(likes: 9)

      expect(Article.order_by_component(Counter, prefix: :likes, direction: :desc)).to eq [high, low]
    end

    it "demands a column when the component declares no primary attribute" do
      expect { User.order_by_component(Group) }.to raise_error(ArgumentError, /no primary attribute/)
    end

    it "orders by the given slot, not another" do
      stub_const("Customer", Class.new(ApplicationEntity))
      Customer.component Address
      Customer.component Address, prefix: :business
      x = Customer.create!(address_region: "A", business_address_region: "Z")
      y = Customer.create!(address_region: "Z", business_address_region: "A")

      expect(Customer.order_by_component(Address, :region, prefix: :business)).to eq [y, x]
      expect(Customer.order_by_component(Address, :region)).to eq [x, y]
    end

    it "composes with with_component and ordinary ActiveRecord" do
      a = user_titled("alpha")
      user_titled("beta")
      c = user_titled("gamma")
      a.email.update!(address: "a@x.com")
      c.email.update!(address: "c@x.com")

      expect(User.with_component(Email).order_by_component(Group, :title, :desc).limit(2)).to eq [c, a]
      expect(User.with_component(Email).order_by_component(Group, :title).count).to eq 2
    end

    it "chains a second component order as a tiebreak" do
      a1 = user_titled("alpha")
      a1.email.update!(address: "b@x.com")
      a2 = user_titled("alpha")
      a2.email.update!(address: "a@x.com")

      expect(User.order_by_component(Group, :title).order_by_component(Email, :address)).to eq [a2, a1]
    end

    it "keeps the entity-model scope and does not duplicate rows" do
      user_titled("alpha")
      post = Post.create!
      post.name.first = "x"
      post.save!
      sql = User.order_by_component(Group, :title).to_sql

      aggregate_failures do
        expect(sql).to include('"entities"."model" = \'users\'')
        expect(sql).to match(/ORDER BY \(SELECT "groups"\."title" FROM "groups" WHERE .*LIMIT 1\) ASC NULLS LAST/m)
        expect(User.order_by_component(Group, :title).to_a.size).to eq User.count
      end
    end

    it "rejects an unknown column, since it is interpolated into SQL" do
      expect { User.order_by_component(Group, :nope) }.to raise_error(ArgumentError, /no column :nope/)
      expect { User.order_by_component(Group, "title; DROP TABLE users") }.to raise_error(ArgumentError, /no column/)
    end

    it "rejects a bad direction or nulls option" do
      expect { User.order_by_component(Group, :title, :sideways) }.to raise_error(ArgumentError, /direction/)
      expect { User.order_by_component(Group, :title, nulls: :middle) }.to raise_error(ArgumentError, /nulls/)
    end

    it "rejects a non-component" do
      expect { User.order_by_component(String, :x) }.to raise_error(EcsRails::InvalidComponent)
    end
  end
end
