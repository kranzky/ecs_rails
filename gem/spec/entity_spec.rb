# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0001 and the entity invariants in architecture.md §1 / §3.
#
# A sub-subclass. Entity classes are ordinary AR classes, so a host app can
# specialise one. Pinned here because "does the subclass filter inherit?" is
# otherwise the kind of thing that silently regresses.
class Admin < User
end

RSpec.describe EcsRails::Entity do
  describe "the abstract base" do
    it "is abstract" do
      expect(described_class.abstract_class?).to be true
    end

    it "lives in the entities table" do
      expect(described_class.table_name).to eq "entities"
    end

    it "cannot be instantiated" do
      expect { described_class.new }.to raise_error(NotImplementedError)
    end

    it "is abstract in the host app too" do
      expect(ApplicationEntity.abstract_class?).to be true
    end
  end

  describe "the model discriminator" do
    # RFC-0001: "model is set on create from the subclass's model_name.plural".
    it "stamps the model discriminator on create" do
      expect(User.create!.model).to eq "users"
    end

    it "stamps a different discriminator per subclass" do
      expect(Post.create!.model).to eq "posts"
    end

    # Pins the default_scope create-leak: the discriminator is already visible
    # on an unsaved record, not conjured at INSERT time.
    it "stamps the discriminator on new, before save" do
      expect(User.new.model).to eq "users"
    end

    # The discriminator is derived, never host-supplied. A caller cannot forge
    # an identity by passing model: on create.
    it "ignores a caller-supplied model" do
      expect(User.create!(model: "posts").model).to eq "users"
    end

    # ...even outside the default scope, where scope_for_create gives us nothing.
    it "stamps the discriminator even when created unscoped" do
      expect(User.unscoped.create!.model).to eq "users"
    end

    it "derives the discriminator for a sub-subclass" do
      expect(Admin.create!.model).to eq "admins"
    end
  end

  describe "subclass scoping" do
    it "scopes queries to the subclass" do
      User.create!
      Post.create!
      expect(User.all.count).to eq 1
    end

    # ADR-0002 / architecture.md §2: the common query is one indexed table scan.
    it "compiles to a single filtered table scan" do
      expect(User.all.to_sql).to match(/FROM "entities".*"model" = 'users'/)
    end

    it "does not find another subclass's entity by id" do
      post = Post.create!
      expect { User.find(post.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "inherits the filter into a sub-subclass" do
      Admin.create!
      User.create!
      expect(Admin.all.count).to eq 1
    end

    # Consequence of deriving the filter from each class's own plural: a
    # sub-subclass is a sibling at query time, not a member of its parent.
    it "does not return sub-subclass rows from the parent" do
      Admin.create!
      expect(User.all.count).to eq 0
    end
  end

  describe "the abstract base as a query root" do
    # RFC-0001: "ApplicationEntity itself applies no filter".
    it "queries across all entities" do
      User.create!
      Post.create!
      expect(ApplicationEntity.all.count).to eq 2
    end

    it "applies no model filter in SQL" do
      expect(ApplicationEntity.all.to_sql).not_to include "model"
    end

    it "reads back rows created through a subclass" do
      user = User.create!
      expect(ApplicationEntity.find(user.id).model).to eq "users"
    end
  end

  describe "immutable identity" do
    it "has an immutable identity" do
      user = User.create!
      expect { user.update!(model: "posts") }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "raises on direct model assignment after create" do
      user = User.create!
      expect { user.model = "posts" }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "raises on id assignment after create" do
      user = User.create!
      expect { user.id = SecureRandom.uuid }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "raises on write_attribute after create" do
      user = User.create!
      expect { user.write_attribute(:model, "posts") }
        .to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "leaves the persisted model untouched after a rejected write" do
      user = User.create!
      begin
        user.update!(model: "posts")
      rescue ActiveRecord::ReadonlyAttributeError
        # expected — asserted above; here we only care that nothing was written
      end
      expect(user.reload.model).to eq "users"
    end

    it "declares id and model readonly" do
      expect(User.readonly_attributes).to contain_exactly("id", "model")
    end
  end

  describe "the entities row" do
    it "has a UUID primary key" do
      expect(User.create!.id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "does not track updated_at" do
      expect(User.column_names).not_to include "updated_at"
    end

    it "holds no domain state" do
      expect(User.column_names).to contain_exactly("id", "model", "created_at")
    end

    it "stamps created_at" do
      expect(User.create!.created_at).to be_within(5).of(Time.current)
    end
  end
end
