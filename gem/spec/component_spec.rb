# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0003 and the subclass resolution it depends on (ADR-0008).
#
# The entity classes below are declared here rather than in support/models.rb
# because they exist to pin inflection behaviour, not to read like a host app —
# the same reason entity_spec.rb declares `Admin` locally.
#
# Entity classes need no table of their own: every entity shares `entities`
# (ADR-0002), so these cost nothing but a constant.

# An irregular plural: "person" => "people".
class Person < ApplicationEntity
end

# An irregular plural that changes stem: "datum" => "data".
class Datum < ApplicationEntity
end

# An uncountable: "equipment" => "equipment".
class Equipment < ApplicationEntity
end

# A namespaced entity, and its un-namespaced twin. The pair exists to prove the
# discriminator keeps them distinct: under model_name.plural both collapse onto
# "blog_posts", which is why ADR-0008 derives it from model_name.collection
# instead ("blog/posts" vs "blog_posts").
#
# Defining BlogPost as a real entity is what makes the collision test honest —
# it is the class that .plural would wrongly resolve Blog::Post rows to.
module Blog
  class Post < ApplicationEntity
  end
end

class BlogPost < ApplicationEntity
end

# A sub-subclass, to check resolution reaches the leaf. Declared here rather
# than reusing entity_spec's `Admin` so this file stands alone.
class Superuser < User
end

RSpec.describe EcsRails::Component do
  describe "the abstract base" do
    it "is abstract" do
      expect(described_class.abstract_class?).to be true
    end

    it "is abstract in the host app too" do
      expect(ApplicationComponent.abstract_class?).to be true
    end

    it "is an ordinary ActiveRecord model" do
      expect(described_class.ancestors).to include ActiveRecord::Base
    end
  end

  describe "belonging to an entity" do
    # RFC-0003's own test, verbatim.
    it "belongs to its entity" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect(Email.first.entity).to eq user
    end

    it "targets the abstract ApplicationEntity" do
      expect(Email.reflect_on_association(:entity).options[:class_name])
        .to eq "ApplicationEntity"
    end

    # The FK is a UUID pointing at entities.id.
    it "reads the entity through entity_id" do
      user = User.create!
      expect(Email.create!(entity: user, address: "a@b.com").entity_id).to eq user.id
    end

    it "accepts an entity subclass instance on assignment" do
      user = User.create!
      expect { Email.create!(entity: user, address: "a@b.com") }.not_to raise_error
    end
  end

  describe "entity_id is required" do
    it "refuses a component with no entity" do
      expect(Email.new(address: "a@b.com")).not_to be_valid
    end

    it "reports the missing entity" do
      email = Email.new(address: "a@b.com")
      email.valid?
      expect(email.errors[:entity]).to be_present
    end

    # RFC-0003 / ADR-0005: unique per table, DB-enforced.
    it "refuses a second row for one entity" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect { Email.create!(entity: user, address: "x@y.com") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The same entity may of course carry different component types.
    it "allows different component types on one entity" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect { Name.create!(entity: user, first: "Ada") }.not_to raise_error
    end
  end

  describe "querying components directly" do
    # RFC-0003: components are queried directly and normally.
    it "is queryable without touching entities" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect(Email.where(verified: false).count).to eq 1
    end

    it "does not join entities" do
      expect(Email.where(verified: false).to_sql).not_to include "entities"
    end

    it "applies no discriminator filter of its own" do
      expect(Email.all.to_sql).not_to include "model"
    end

    it "supports find_each" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      found = []
      Email.find_each { |e| found << e.address }
      expect(found).to eq ["a@b.com"]
    end
  end

  # ADR-0001: a component method's self is the component, never the entity.
  describe "method binding" do
    it "binds self to the component" do
      user = User.create!
      email = Email.create!(entity: user, address: "a@b.com")
      expect(email.who_am_i).to be email
    end

    it "binds self to the component when reached through a query" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect(Email.first.who_am_i).to be_a Email
    end
  end

  # The crux: ADR-0008. `component.entity` must return the real subclass.
  describe "subclass resolution on read" do
    it "returns the entity as its real subclass" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect(Email.first.entity).to be_a User
    end

    it "resolves through ApplicationEntity.find" do
      user = User.create!
      expect(ApplicationEntity.find(user.id)).to be_a User
    end

    it "resolves a different subclass from the same table" do
      post = Post.create!
      expect(ApplicationEntity.find(post.id)).to be_a Post
    end

    it "resolves through a plain relation, not just find" do
      User.create!
      expect(ApplicationEntity.first).to be_a User
    end

    it "resolves through the subclass's own query too" do
      user = User.create!
      expect(User.find(user.id)).to be_a User
    end

    it "resolves a sub-subclass to itself" do
      superuser = Superuser.create!
      expect(ApplicationEntity.find(superuser.id)).to be_a Superuser
    end

    it "resolves eager-loaded entities" do
      user = User.create!
      Email.create!(entity: user, address: "a@b.com")
      expect(Email.includes(:entity).first.entity).to be_a User
    end

    # A partial select has no `model` to discriminate on. Resolution must fall
    # back to the queried class rather than raise — `select`/`pluck` are
    # ordinary AR usage and RFC-0003 keeps components ordinary AR models.
    it "falls back to the queried class when model was not selected" do
      User.create!
      expect { ApplicationEntity.select(:id).first }.not_to raise_error
    end

    it "still resolves when model is among the selected columns" do
      User.create!
      expect(ApplicationEntity.select(:id, :model).first).to be_a User
    end

    # ADR-0008 is explicit that instantiating via allocate must not trip the
    # RFC-0001 readonly guard.
    it "does not trip the immutable identity guard on load" do
      user = User.create!
      expect { ApplicationEntity.find(user.id) }.not_to raise_error
    end

    it "still enforces immutability on a resolved subclass" do
      user = User.create!
      expect { ApplicationEntity.find(user.id).model = "posts" }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end
  end

  # The abstract base must stay a query root. Resolution happens at
  # instantiation, so it must not leak a filter into the query.
  describe "the abstract base as a query root, after resolution" do
    it "still queries across all entities" do
      User.create!
      Post.create!
      expect(ApplicationEntity.all.count).to eq 2
    end

    it "still applies no model filter in SQL" do
      expect(ApplicationEntity.all.to_sql).not_to include "model"
    end

    it "returns a heterogeneous set as its several subclasses" do
      User.create!
      Post.create!
      expect(ApplicationEntity.all.map(&:class)).to contain_exactly(User, Post)
    end

    it "still scopes a subclass to its own discriminator" do
      User.create!
      Post.create!
      expect(User.all.count).to eq 1
    end
  end

  # ADR-0008: "An unresolvable model (class deleted or renamed) will raise
  # NameError at instantiation. Consistent with the registry's fail-loudly
  # stance."
  describe "an unresolvable model" do
    # Insert directly: there is no way to create a row for a class that does
    # not exist through the ordinary API.
    def insert_ghost!
      ApplicationEntity.connection.execute(
        "INSERT INTO entities (model, created_at) VALUES ('ghosts', NOW())"
      )
    end

    it "raises NameError at instantiation" do
      insert_ghost!
      expect { ApplicationEntity.where(model: "ghosts").first }.to raise_error(NameError)
    end

    it "names the offending discriminator in the message" do
      insert_ghost!
      expect { ApplicationEntity.where(model: "ghosts").first }
        .to raise_error(NameError, /ghosts/)
    end

    it "does not raise when merely counting" do
      insert_ghost!
      expect { ApplicationEntity.where(model: "ghosts").count }.not_to raise_error
    end
  end

  # ADR-0008: "model values must round-trip:
  # User.model_name.plural.classify.constantize must return User. This holds for
  # ordinary names but not universally."
  #
  # These assert on the *observed values*, not just on a boolean, so that a
  # regression reports what the inflector actually did.
  describe "the inflection round-trip" do
    # Mirrors what Entity#stamp_model writes and what
    # .discriminate_class_for_record reads back. See ADR-0008.
    def round_trip(klass)
      klass.model_name.collection.classify.constantize
    end

    context "an ordinary name" do
      it "pluralises to 'users'" do
        expect(User.model_name.plural).to eq "users"
      end

      it "round-trips" do
        expect(round_trip(User)).to eq User
      end
    end

    # Rails' inflector is bidirectional for its irregular rules, so these all
    # invert cleanly. Verified, not assumed.
    context "an irregular plural" do
      it "pluralises Person to 'people'" do
        expect(Person.model_name.plural).to eq "people"
      end

      it "round-trips Person" do
        expect(round_trip(Person)).to eq Person
      end

      it "pluralises Datum to 'data'" do
        expect(Datum.model_name.plural).to eq "data"
      end

      it "round-trips Datum" do
        expect(round_trip(Datum)).to eq Datum
      end
    end

    context "an uncountable" do
      it "pluralises Equipment to 'equipment'" do
        expect(Equipment.model_name.plural).to eq "equipment"
      end

      it "round-trips Equipment" do
        expect(round_trip(Equipment)).to eq Equipment
      end
    end

    # Namespacing is why the discriminator is derived from model_name.collection
    # rather than model_name.plural. See the ADR-0008 amendment.
    #
    # These first two examples are statements about ActiveSupport, not about
    # ECS Rails: .plural underscores the whole constant path, destroying the
    # namespace separator before the inflector is ever consulted. They are kept
    # because they are the entire argument for not using .plural — if they ever
    # stop being true, the amendment can be revisited.
    context "why not model_name.plural" do
      it "loses the namespace: Blog::Post pluralises to 'blog_posts'" do
        expect(Blog::Post.model_name.plural).to eq "blog_posts"
      end

      it "classifies back to the wrong constant name" do
        expect(Blog::Post.model_name.plural.classify).to eq "BlogPost"
      end

      # The killer argument: the mapping is not injective. Blog::Post and
      # BlogPost collapse onto one discriminator, so no inverse function —
      # however perfect, however custom the inflection rule — could ever
      # separate them. This is why the fix has to be a different source string.
      it "collides: Blog::Post and BlogPost share a discriminator" do
        expect(Blog::Post.model_name.plural).to eq BlogPost.model_name.plural
      end
    end

    context "a namespaced class, via model_name.collection" do
      it "keeps the namespace: 'blog/posts'" do
        expect(Blog::Post.model_name.collection).to eq "blog/posts"
      end

      it "round-trips to the right constant" do
        expect(round_trip(Blog::Post)).to eq Blog::Post
      end

      it "stamps the lossless discriminator on create" do
        expect(Blog::Post.create!.model).to eq "blog/posts"
      end

      # The behaviour that matters: a namespaced entity is no longer write-only.
      it "writes a namespaced entity and reads it back as itself" do
        post = Blog::Post.create!
        expect(ApplicationEntity.find(post.id)).to be_a Blog::Post
      end

      it "does not collide with the un-namespaced class of the same name" do
        expect(Blog::Post.model_name.collection).not_to eq BlogPost.model_name.collection
      end

      it "reads BlogPost back as BlogPost, not Blog::Post" do
        expect(ApplicationEntity.find(BlogPost.create!.id)).to be_an_instance_of BlogPost
      end

      # Why this needed no data migration: for every non-namespaced class the
      # two derivations are byte-identical, so existing discriminators are
      # already correct under .collection.
      it "is identical to .plural for ordinary names" do
        [User, Post, Person, Datum, Equipment, BlogPost].each do |klass|
          expect(klass.model_name.collection).to eq klass.model_name.plural
        end
      end
    end
  end
end
