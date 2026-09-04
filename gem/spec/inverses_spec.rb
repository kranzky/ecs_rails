# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0015: inverse relationships — the parent side of `relates_to`
# as `has_many` / `has_one` over the shared `relationships` table (ADR-0017).
#
#   Post relates_to :author, User      →   User has_many :posts, Post, via: :author
#   Membership relates_to :team, Team  →   Team has_many :memberships, Membership, via: :team
#
# The expansion is native has_many :through over Relationship rows keyed on
# target_id, scoped by slot AND owner_model, with class_name on the through so
# the collection is of the child class. Everything after that is Rails, which
# is the point: a real CollectionProxy, real preloading, no new storage.
#
# Comment ALSO relates :author to User (RFC-0013's fixture), sharing the table
# and the slot with Post — so "user.posts contains no comments" is a real
# assertion that owner_model on the link scope is load-bearing.
RSpec.describe "inverse relationships" do
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- the RFC's contract ----------------------------------------------------
  describe "has_many" do
    it "reads the collection through the shared table, as the child class" do
      ada = User.create!
      post = Post.create!(author: ada)

      aggregate_failures do
        expect(ada.posts).to contain_exactly(post)
        expect(ada.posts.first).to be_an_instance_of Post # ADR-0008 through the through
        expect(ada.posts).to be_a ActiveRecord::Associations::CollectionProxy
      end
    end

    it "does not collect another entity type using the same slot name" do
      # Comment relates :author to the same user, in the same table, under the
      # same slot. owner_model (and class_name) keep it out.
      ada = User.create!
      Comment.create!(author: ada)
      post = Post.create!(author: ada)

      expect(ada.posts).to contain_exactly(post)
    end

    it "does not collect another user's children" do
      ada = User.create!
      Post.create!(author: User.create!)

      expect(ada.posts).to be_empty
    end

    it "appends with <<, writing the link row with slot and owner model preset" do
      ada = User.create!
      post = Post.create!
      ada.posts << post

      link = Relationship.find_by!(entity_id: post.id)
      aggregate_failures do
        expect(link.slot).to eq "author"
        expect(link.owner_model).to eq "posts"
        expect(link.target_id).to eq ada.id
        expect(post.reload.author).to eq ada
      end
    end

    it "creates a child whose relationship points back" do
      ada = User.create!
      post = ada.posts.create!(name_first: "Hello")

      aggregate_failures do
        expect(post).to be_an_instance_of Post
        expect(post.reload.author).to eq ada
        expect(post.name_first).to eq "Hello"
        expect(ada.posts.reload).to contain_exactly(post)
      end
    end

    it "builds a child that the parent's save persists and links — standard has_many :through" do
      ada = User.create!
      post = ada.posts.build(name_first: "built")
      expect(post).to be_new_record

      ada.save! # autosave inserts the new child and its link row
      aggregate_failures do
        expect(post).to be_persisted
        expect(post.reload.author).to eq ada
        expect(post.name_first).to eq "built"
      end
    end

    it "does not link a built child that saves itself first — its own save knows nothing of the parent" do
      # The Rails rule for any has_many :through: the join row is the parent's
      # to write. Use << or create! to link immediately.
      ada = User.create!
      post = ada.posts.build
      post.save!

      expect(Relationship.where(entity_id: post.id)).to be_empty
    end

    it "preloads without N+1" do
      3.times { Post.create!(author: User.create!) }

      sql = capture_sql { User.all.includes(:posts).each { |u| u.posts.to_a } }

      expect(sql.size).to eq 3 # users, links, posts
    end

    it "chains scopes and the component query DSL" do
      ada = User.create!
      named = ada.posts.create!(name_first: "named")
      ada.posts.create!

      expect(ada.posts.with_component(Name, first: "named")).to contain_exactly(named)
      expect(ada.posts.order(created_at: :desc).size).to eq 2
    end

    it "handles a join entity's two parents" do
      user = User.create!
      team = Team.create!
      membership = Membership.create!(user: user, team: team)

      aggregate_failures do
        expect(user.memberships).to contain_exactly(membership)
        expect(team.memberships).to contain_exactly(membership)
        expect(user.memberships.first.team).to eq team
      end
    end

    it "is inherited by a subclass of the parent" do
      stub_const("Admin", Class.new(User))
      admin = Admin.create!
      post = Post.create!(author: admin)

      expect(admin.posts).to contain_exactly(post)
    end

    it "infers the child from the reader name, or takes a name, or a class" do
      # The fixture's `has_many :posts, via: :author` is the inferred form.
      stub_const("Author", Class.new(User))
      Author.has_many :writings, "Post", via: :author   # named
      Author.has_many :articles, Post, via: :author     # a class

      author = Author.create!
      post = Post.create!(author: author)

      aggregate_failures do
        expect(User.inverse_meta(:posts).child_class_name).to eq "Post"     # inferred
        expect(Author.inverse_meta(:writings).child_class_name).to eq "Post"
        expect(author.posts).to contain_exactly(post)
        expect(author.writings).to contain_exactly(post)
        expect(author.articles).to contain_exactly(post)
      end
    end

    it "records the inverse's metadata" do
      meta = User.inverse_meta(:posts)

      aggregate_failures do
        expect(meta.macro).to eq :has_many
        expect(meta.child_class).to eq Post
        expect(meta.via).to eq :author
        expect(meta.link_name).to eq :posts_author_links
        expect(User.inverses.map(&:name)).to eq %i[posts memberships]
      end
    end
  end

  # --- dependent: on the link rows ---------------------------------------------
  describe "dependent:" do
    before { EcsRails.registry.clear! }

    it "destroys the link rows with the parent, so no orphan pointer is left" do
      stub_const("Author", Class.new(User))
      Author.has_many :writings, Post, via: :author, dependent: :destroy
      author = Author.create!
      post = Post.create!(author: author)

      author.destroy

      aggregate_failures do
        expect(Relationship.where(entity_id: post.id)).to be_empty # the link is gone, not nullified
        expect(Post.exists?(post.id)).to be true                     # the child entity stays
      end
    end

    it "nullifies the pointer by default (the foreign key's behaviour)" do
      ada = User.create!
      post = Post.create!(author: ada)

      ada.destroy

      link = Relationship.find_by!(entity_id: post.id)
      expect(link.target_id).to be_nil
    end

    it "rejects anything but :destroy or :delete_all" do
      stub_const("Author", Class.new(User))

      expect { Author.has_many :writings, Post, via: :author, dependent: :nullify }
        .to raise_error(ArgumentError, /dependent:.*link rows/)
    end
  end

  # --- has_one -----------------------------------------------------------------
  describe "has_one" do
    before do
      EcsRails.registry.clear!
      stub_const("Invoice", Class.new(ApplicationEntity))
      Invoice.relates_to :team, Team, unique: true
      stub_const("Club", Class.new(Team))
      Club.has_one :invoice, via: :team
    end

    it "reads the single child, or nil" do
      club = Club.create!
      expect(club.invoice).to be_nil

      invoice = Invoice.create!(team: club)
      expect(club.reload.invoice).to eq invoice
      expect(club.invoice).to be_an_instance_of Invoice
    end

    it "creates through the parent, linking immediately" do
      # ActiveRecord's has_one :through would leave the join row for the owner's
      # next save; the guard flushes it so create_invoice! means what it says.
      club = Club.create!
      invoice = club.create_invoice!

      aggregate_failures do
        expect(invoice.reload.team).to eq club
        expect(Relationship.find_by!(entity_id: invoice.id).exclusive).to be true
        expect(club.reload.invoice).to eq invoice
      end
    end

    it "links on assignment" do
      club = Club.create!
      invoice = Invoice.create!
      club.invoice = invoice

      expect(invoice.reload.team).to eq club
    end

    it "builds a child that the owner's save links" do
      club = Club.create!
      invoice = club.build_invoice
      club.save!

      expect(invoice).to be_persisted
      expect(invoice.reload.team).to eq club
    end

    it "is enforced at the database by the child's unique: true" do
      club = Club.create!
      Invoice.create!(team: club)

      expect { Invoice.create!(team: club) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses a has_one over a relationship not declared unique — on first use" do
      Club.has_one :membership, via: :team # declaring is fine: the child may not be loaded yet

      expect { Club.create!.membership }.to raise_error(EcsRails::InvalidRelationship, /unique: true/)
      expect { Club.validate_inverses! }.to raise_error(EcsRails::InvalidRelationship, /unique: true/)
    end

    it "guards build and create as well as the reader" do
      Club.has_one :membership, via: :team

      expect { Club.create!.create_membership! }.to raise_error(EcsRails::InvalidRelationship)
    end
  end

  # --- validation --------------------------------------------------------------
  #
  # On first use, not at class-load time: the parent names the child and the
  # child's relates_to names the parent, and under autoloading a constant
  # reference from either body loads the other half-defined. So `has_many`
  # records the child's NAME, and the pair is checked when the association is
  # first read (or by validate_inverses!, which the Railtie calls at boot under
  # eager_load).
  describe "validation" do
    before { EcsRails.registry.clear! }

    it "rejects a component class as the child, immediately — that mistake is visible at once" do
      stub_const("Parent", Class.new(ApplicationEntity))

      expect { Parent.has_many :things, Email, via: :owner }.to raise_error(EcsRails::InvalidRelationship, /expected an entity/)
    end

    it "accepts a declaration whose child is not loaded yet" do
      stub_const("Parent", Class.new(User))

      expect { Parent.has_many :drafts, "NotYetDefined", via: :author }.not_to raise_error
      expect { Parent.create!.drafts }.to raise_error(EcsRails::InvalidRelationship, /no entity class named NotYetDefined/)
    end

    it "rejects a via the child does not declare, listing what it does, on first use" do
      stub_const("Parent", Class.new(User))
      Parent.has_many :edited, "Post", via: :editor

      expect { Parent.create!.edited }
        .to raise_error(EcsRails::InvalidRelationship, /no relationship :editor.*:author.*relates_to :editor/m)
    end

    it "rejects a via that points at a different entity, on first use" do
      stub_const("Parent", Class.new(ApplicationEntity))
      Parent.has_many :posts, via: :author # Parent is not a User

      expect { Parent.validate_inverses! }
        .to raise_error(EcsRails::InvalidRelationship, /relates :author to User, not to Parent/)
    end

    it "validates once per class, then reads freely" do
      stub_const("Parent", Class.new(User))
      Parent.has_many :writings, "Post", via: :author
      parent = Parent.create!
      Post.create!(author: parent)

      expect(parent.writings.size).to eq 1
      expect(Parent.create!.writings).to be_empty
    end

    it "requires via: when an entity class is given" do
      stub_const("Parent", Class.new(User))

      expect { Parent.has_many :posts, Post }.to raise_error(ArgumentError, /needs `via:`/)
    end

    it "rejects a name the entity already answers" do
      stub_const("Parent", Class.new(User))
      Parent.component Group

      expect { Parent.has_many :group, Post, via: :author }.to raise_error(EcsRails::DelegationConflict, /#group/)
    end

    it "reserves its names against later components and markers" do
      stub_const("Parent", Class.new(User))
      Parent.has_many :writings, Post, via: :author
      stub_const("Writings", Class.new(ApplicationComponent) { self.table_name = "avatars" })

      expect { Parent.marker :writings }.to raise_error(EcsRails::DelegationConflict)
      expect { Parent.relates_to :writings, Team }.to raise_error(EcsRails::DelegationConflict)
    end

    it "leaves ActiveRecord's has_many and has_one alone without via:" do
      # The DSL's own slot-scoped has_one for a component reader goes through
      # the same method and must still be a plain ActiveRecord association.
      expect(User.reflect_on_association(:email).macro).to eq :has_one
      expect(User.reflect_on_association(:email).klass).to eq Email
    end
  end

  # --- the wildcard ------------------------------------------------------------
  describe "referrers" do
    it "lists every relationship row pointing at an entity, whatever its name" do
      ada = User.create!
      post = Post.create!(author: ada)
      comment = Comment.create!(author: ada)
      membership = Membership.create!(user: ada)

      aggregate_failures do
        expect(ada.referrers.pluck(:entity_id)).to contain_exactly(post.id, comment.id, membership.id)
        expect(ada.referrers.pluck(:owner_model, :slot))
          .to contain_exactly(%w[posts author], %w[comments author], %w[memberships user])
        expect(ada.referrers(slot: :user).pluck(:entity_id)).to eq [membership.id]
      end
    end

    it "is empty for an entity nothing points at" do
      expect(User.create!.referrers).to be_empty
    end
  end
end
