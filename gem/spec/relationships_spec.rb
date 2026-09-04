# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0012: the relationship DSL — `relates_to`, decided by ADR-0013
# and re-based on the shared `relationships` table by ADR-0017.
#
# These are the RFC's contract tests, ADAPTED to the gem's fixtures. The RFC's
# examples use the demo's models (`Post relates_to :author, User`;
# `Membership relates_to :user/:group`). The gem's fixtures give the same shapes:
#
#   - Post declares `relates_to :author, User` (spec/support/models.rb): a row in
#     `relationships` under slot "author" (spec/support/schema.rb).
#   - Membership is a join entity with `relates_to :user, User` and
#     `relates_to :team, Team` — the M2M pattern. The RFC's example relates to a
#     `Group`, but the gem's `Group` is a *component*, not an entity, so `Team`
#     stands in as the second target entity.
#
# The public API is unchanged from ADR-0013; what changed is that there is no
# backing class and no table per relationship. Every `relates_to` is a
# `component Relationship, prefix: name` — the same slot mechanism RFC-0014
# built — so the shared-table specifics down the page are the new ground.
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

    it "exposes the writer" do
      expect(Post.new).to respond_to(:author, :author=)
    end

    it "exposes the id accessors too" do
      post = Post.create!
      user = User.create!
      post.author_id = user.id
      post.save!

      expect(post.reload.author_id).to eq user.id
      expect(post.author).to eq user
    end

    it "routes flat mass assignment" do
      user = User.create!
      post = Post.create!(author: user)

      expect(post.reload.author).to eq user
      expect(Post.create!(author_id: user.id).reload.author).to eq user
    end

    it "returns the concrete entity subclass, not the abstract base (ADR-0008)" do
      post = Post.create!
      post.author = User.create!
      post.save!

      expect(post.reload.author).to be_an_instance_of User
    end
  end

  # ADR-0017: one row in one table. The backing reader is `author_relationship`,
  # the slot-scoped has_one every labelled component gets (RFC-0014).
  describe "the shared relationships table" do
    it "declares the app's Relationship component into a slot named for the relationship" do
      declaration = Post.declaration_for(Relationship, prefix: :author)

      aggregate_failures do
        expect(declaration).not_to be_nil
        expect(declaration.slot).to eq "author"
        expect(declaration.reader_name).to eq :author_relationship
        expect(declaration.options).to eq(delegate: false)
        expect(declaration.slot_options).to eq(target_class_name: "User", unique: false)
      end
    end

    it "exposes the backing reader as <relation>_relationship" do
      aggregate_failures do
        expect(Post.new).to respond_to(:author_relationship)
        expect(Post.new.author_relationship).to be_a Relationship
        expect(Post.new.author_relationship.slot).to eq "author"
      end
    end

    it "writes the row under the relationship's slot, with the owner's model stamped" do
      post = Post.create!
      user = User.create!
      post.author = user
      post.save!

      row = Relationship.find_by!(entity_id: post.id, slot: "author")
      aggregate_failures do
        expect(row.target_id).to eq user.id
        expect(row.owner_model).to eq "posts"
        expect(row.exclusive).to be false
      end
    end

    it "writes nothing for an unset relationship" do
      post = Post.create!
      post.author # read it

      expect { post.save! }.not_to change(Relationship, :count)
    end

    it "does not delegate the component's own accessors" do
      # `author` is defined by relates_to; `target` and friends stay behind the reader.
      expect(Post.new).not_to respond_to(:author_relationship_target, :target, :owner_model, :exclusive)
    end

    it "is the key includes_components and with_component see" do
      post = Post.create!
      post.author = User.create!
      post.save!

      expect(Post.includes_components(Relationship)).to include(post)
      expect(Post.with_component(Relationship, prefix: :author)).to include(post)
    end

    it "lists Relationship once among the entity's components" do
      expect(Membership.components).to eq [Relationship]
      expect(Membership.component_declarations.map(&:slot)).to eq %w[user team]
    end

    it "keeps two entity types sharing a slot name apart" do
      # Post and Comment both relate :author; both rows sit in one table under
      # slot "author". Only the owner's model tells them apart (ADR-0014, amended).
      ada = User.create!
      post = Post.create!(author: ada)
      comment = Comment.create!(author: ada)

      aggregate_failures do
        expect(Relationship.where(slot: "author").count).to eq 2
        expect(post.reload.author).to eq ada
        expect(comment.reload.author).to eq ada
        expect(Relationship.find_by!(entity_id: post.id).owner_model).to eq "posts"
        expect(Relationship.find_by!(entity_id: comment.id).owner_model).to eq "comments"
      end
    end
  end

  # ADR-0017: the target type was enforced by `belongs_to class_name:` under
  # ADR-0013; with one generic target column the gem enforces it in Ruby, and
  # the check is mandatory, not optional.
  describe "the target type" do
    it "raises on assignment of the wrong entity type" do
      post = Post.create!

      expect { post.author = Team.create! }
        .to raise_error(EcsRails::InvalidRelationship, /relates_to :author on Post points at User; got Team/)
    end

    it "accepts a subclass of the declared target" do
      stub_const("Admin", Class.new(User))
      post = Post.create!
      admin = Admin.create!
      post.author = admin
      post.save!

      expect(post.reload.author).to eq admin
    end

    it "accepts nil" do
      post = Post.create!(author: User.create!)
      post.author = nil
      post.save!

      expect(post.reload.author).to be_nil
    end

    it "knows its declared target class" do
      expect(Post.new.author_relationship.target_class).to eq User
      expect(Post.new.author_relationship.target_class_name).to eq "User"
    end
  end

  # ADR-0017: `unique: true` writes `exclusive`, and the partial unique index
  # makes the link one-to-one at the database — with no index of its own.
  describe "unique: true" do
    before do
      EcsRails.registry.clear!
      stub_const("Invoice", Class.new(ApplicationEntity))
      Invoice.relates_to :team, Team, unique: true
    end

    it "stamps exclusive on the row" do
      invoice = Invoice.create!(team: Team.create!)

      expect(Relationship.find_by!(entity_id: invoice.id).exclusive).to be true
    end

    it "is recorded in the metadata and the declaration" do
      expect(Invoice.relationship_meta(:team).unique).to be true
      expect(Invoice.declaration_for(Relationship, prefix: :team).slot_options[:unique]).to be true
    end

    it "rejects a second Invoice for the same Team at the database" do
      team = Team.create!
      Invoice.create!(team: team)

      expect { Invoice.create!(team: team) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "does not constrain a non-unique relationship to the same target" do
      team = Team.create!
      Membership.create!(team: team)

      expect { Membership.create!(team: team) }.not_to raise_error
    end

    it "does not constrain a different owner type pointing at the same target" do
      # Exclusivity is per (target, slot, owner_model): a Membership's :team and
      # an Invoice's :team do not collide.
      team = Team.create!
      Invoice.create!(team: team)

      expect { Membership.create!(team: team) }.not_to raise_error
    end

    it "rejects a non-Boolean" do
      klass = stub_const("Bad", Class.new(ApplicationEntity))

      expect { klass.relates_to :team, Team, unique: :yes }.to raise_error(ArgumentError, /unique:/)
    end
  end

  # THE load-bearing behaviour (ADR-0013, kept by ADR-0017): the target FK is
  # NULLIFY, not cascade; the owner FK cascades. Asserted against the real
  # database, not the migration text.
  describe "deletion" do
    it "nullifies on target deletion, does not cascade to the owner" do
      post = Post.create!
      user = User.create!
      post.author = user
      post.save!

      user.destroy

      aggregate_failures do
        expect(Post.exists?(post.id)).to be true          # the owner survives
        expect(post.reload.author).to be_nil              # the link is nulled
        expect(Relationship.where(entity_id: post.id).exists?).to be true # row survives, target_id NULL
      end
    end

    it "cascades on owner deletion" do
      post = Post.create!(author: User.create!)

      post.destroy

      expect(Relationship.where(entity_id: post.id).exists?).to be false
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

    it "raises when a later bare component would delegate a relationship's name" do
      # ADR-0004 in the other direction: relates_to :author reserved #author, so a
      # component whose bare delegation includes `author` cannot join it.
      stub_const("Author", Class.new(ApplicationComponent) { self.table_name = "sponsors" })
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.relates_to :sponsor, User

      expect { klass.component Author, prefix: false }
        .to raise_error(EcsRails::DelegationConflict, /#sponsor.*relates_to :sponsor/m)
    end

    it "raises when the name's _id accessor is already a delegated method" do
      # Backer reads the sponsors table without the belongs_to, so bare it
      # delegates `sponsor_id` but not `sponsor`; relates_to :sponsor would
      # define `sponsor_id` too.
      stub_const("Backer", Class.new(ApplicationComponent) { self.table_name = "sponsors" })
      klass = stub_const("Clash", Class.new(ApplicationEntity))
      klass.component Backer, prefix: false

      expect { klass.relates_to :sponsor, User }
        .to raise_error(EcsRails::DelegationConflict, /#sponsor_id/)
    end

    it "explains what to do when the app has no Relationship component" do
      EcsRails.config.relationship_class_name = "NoSuchRelationship"
      klass = stub_const("Lonely", Class.new(ApplicationEntity))

      expect { klass.relates_to :author, User }
        .to raise_error(NameError, /ecs_rails:install.*relationship_class_name/m)
    ensure
      EcsRails.config.relationship_class_name = "Relationship"
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

    it "writes one row per relationship, in the one table" do
      membership = Membership.create!(user: User.create!, team: Team.create!)

      expect(Relationship.where(entity_id: membership.id).pluck(:slot)).to contain_exactly("user", "team")
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

    it "stamps the subclass's own model on the row" do
      subclass = stub_const("SpecialPost", Class.new(Post))
      special = subclass.create!(author: User.create!)

      expect(Relationship.find_by!(entity_id: special.id).owner_model).to eq "special_posts"
    end

    it "lists Relationship among the subclass's components" do
      subclass = stub_const("SpecialPost", Class.new(Post))
      expect(subclass.components).to include(Relationship)
      expect(subclass.relationship_names).to eq [:author]
    end
  end

  # Reload safety (RFC-0012): in development Rails drops the entity constant and
  # autoloads a brand-new class under the same name; the Railtie clears the
  # registry on to_prepare. So `relates_to` runs again, on a new class object,
  # against an empty registry — and must not raise DuplicateComponent, and must
  # still work. Simpler than under ADR-0013: there is no backing constant to
  # redefine, only a declaration and metadata keyed by name.
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

    it "does not double-register the declaration" do
      stub_const("Reloadable", Class.new(ApplicationEntity)).relates_to(:author, User)
      reload!.relates_to(:author, User)

      expect(EcsRails.registry.components_for(Reloadable).size).to eq 1
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
