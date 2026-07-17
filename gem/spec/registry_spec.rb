# frozen_string_literal: true

require "spec_helper"

# Throwaway stand-ins for a host app's classes.
#
# The registry is deliberately type-agnostic: RFC-0002 says nothing about
# validating that a component really is a Rorecs::Component (that is RFC-0004's
# InvalidComponent). So these are plain named classes — using real AR models
# here would couple this spec to the schema for no gain.
#
# They live in a namespace so they cannot collide with spec/support/models.rb,
# which already defines top-level Email, Name, User and Post.
module RegistrySpec
  class User; end
  class Post; end
  class Comment; end

  class Email; end
  class Name; end
  class Likes; end
end

RSpec.describe Rorecs::Registry do
  subject(:registry) { Rorecs.registry }

  # The registry is a process-wide singleton, so every example must start clean.
  before { registry.clear! }
  after { registry.clear! }

  def register(entity, component, options = {})
    registry.register(entity_class: entity, component_class: component, options: options)
  end

  describe "#register" do
    it "returns a declaration exposing the entity, component and options" do
      declaration = register(RegistrySpec::User, RegistrySpec::Email, only: [:address])

      expect(declaration.entity_class).to eq RegistrySpec::User
      expect(declaration.component_class).to eq RegistrySpec::Email
      expect(declaration.options).to eq(only: [:address])
    end

    it "defaults options to an empty hash" do
      declaration = registry.register(
        entity_class: RegistrySpec::User,
        component_class: RegistrySpec::Email
      )

      expect(declaration.options).to eq({})
    end

    it "rejects a duplicate declaration of the same component on one entity" do
      register(RegistrySpec::User, RegistrySpec::Email)

      expect { register(RegistrySpec::User, RegistrySpec::Email) }
        .to raise_error(Rorecs::DuplicateComponent, /User.*Email/)
    end

    it "leaves the first declaration intact when a duplicate is rejected" do
      register(RegistrySpec::User, RegistrySpec::Email, only: [:address])
      begin
        register(RegistrySpec::User, RegistrySpec::Email, except: [:address])
      rescue Rorecs::DuplicateComponent
        # expected
      end

      expect(registry.components_for(RegistrySpec::User).map(&:options))
        .to eq [{ only: [:address] }]
    end

    it "allows the same component on different entities" do
      register(RegistrySpec::Post, RegistrySpec::Likes)
      register(RegistrySpec::Comment, RegistrySpec::Likes)

      expect(registry.entities_for(RegistrySpec::Likes))
        .to contain_exactly(RegistrySpec::Post, RegistrySpec::Comment)
    end

    it "refuses an anonymous class" do
      # Entries are keyed by class name; an anonymous class has none. Failing
      # loudly beats silently keying by object identity, which is exactly the
      # reload leak this registry exists to avoid.
      expect { register(Class.new, RegistrySpec::Email) }
        .to raise_error(ArgumentError, /anonymous/)
    end

    it "refuses a non-class" do
      expect { register("RegistrySpec::User", RegistrySpec::Email) }
        .to raise_error(ArgumentError, /Class/)
    end
  end

  describe "#components_for" do
    it "records declarations in declaration order" do
      register(RegistrySpec::User, RegistrySpec::Name)
      register(RegistrySpec::User, RegistrySpec::Email)

      expect(registry.components_for(RegistrySpec::User).map(&:component_class))
        .to eq [RegistrySpec::Name, RegistrySpec::Email]
    end

    it "returns an empty array for an entity that declares nothing" do
      expect(registry.components_for(RegistrySpec::User)).to eq []
    end

    it "does not leak the internal store to callers" do
      register(RegistrySpec::User, RegistrySpec::Name)
      registry.components_for(RegistrySpec::User) << :junk

      expect(registry.components_for(RegistrySpec::User).size).to eq 1
    end
  end

  describe "#entities_for" do
    it "answers the reverse question" do
      register(RegistrySpec::Post, RegistrySpec::Likes)
      register(RegistrySpec::Comment, RegistrySpec::Likes)
      register(RegistrySpec::User, RegistrySpec::Email)

      expect(registry.entities_for(RegistrySpec::Likes))
        .to contain_exactly(RegistrySpec::Post, RegistrySpec::Comment)
    end

    it "returns an empty array for a component nobody declares" do
      expect(registry.entities_for(RegistrySpec::Likes)).to eq []
    end
  end

  describe "#clear!" do
    it "resets both directions of the index" do
      register(RegistrySpec::User, RegistrySpec::Email)
      registry.clear!

      expect(registry.components_for(RegistrySpec::User)).to eq []
      expect(registry.entities_for(RegistrySpec::Email)).to eq []
    end

    it "lets a previously registered pair be registered again" do
      register(RegistrySpec::User, RegistrySpec::Email)
      registry.clear!

      expect { register(RegistrySpec::User, RegistrySpec::Email) }.not_to raise_error
    end
  end

  describe "surviving a Rails development-mode class reload" do
    # Rails' reloader does not mutate a class in place. It removes the constant
    # and autoloads a *brand-new* Class object under the same name. Anything
    # holding the old object now holds a stale, orphaned constant.
    #
    # These examples simulate that honestly: `reload!` really does discard the
    # object and build a new one, and the assertions use `equal` (object
    # identity), so a registry that stashed the class object would fail them.

    def define_reloadable
      RegistrySpec.const_set(:Reloadable, Class.new)
    end

    def reload!
      RegistrySpec.send(:remove_const, :Reloadable)
      RegistrySpec.const_set(:Reloadable, Class.new)
    end

    after do
      RegistrySpec.send(:remove_const, :Reloadable) if RegistrySpec.const_defined?(:Reloadable, false)
    end

    it "stores names, not class objects" do
      # Deliberately white-box: keying by name is the invariant, so assert on it
      # directly rather than inferring it from behaviour alone.
      declaration = register(RegistrySpec::User, RegistrySpec::Email)

      expect(declaration.entity_class_name).to eq "RegistrySpec::User"
      expect(declaration.component_class_name).to eq "RegistrySpec::Email"

      held = declaration.instance_variables.map { |ivar| declaration.instance_variable_get(ivar) }
      expect(held).to all(satisfy { |value| !value.is_a?(Module) })
    end

    it "resolves a reloaded entity to the new class object" do
      original = define_reloadable
      register(original, RegistrySpec::Email)

      reloaded = reload!
      expect(reloaded).not_to equal(original) # a genuinely different object...
      expect(reloaded.name).to eq original.name # ...under the same name

      expect(registry.entities_for(RegistrySpec::Email).first).to equal(reloaded)
    end

    it "resolves a reloaded component to the new class object" do
      original = define_reloadable
      register(RegistrySpec::User, original)

      reloaded = reload!

      declaration = registry.components_for(RegistrySpec::User).first
      expect(declaration.component_class).to equal(reloaded)
      expect(declaration.component_class).not_to equal(original)
    end

    it "resolves a declaration handed out before the reload to the new class" do
      original = define_reloadable
      declaration = register(RegistrySpec::User, original)

      reloaded = reload!

      # The Declaration object predates the reload, yet still resolves forward.
      expect(declaration.component_class).to equal(reloaded)
    end

    it "finds declarations when looked up by the stale pre-reload class object" do
      original = define_reloadable
      register(original, RegistrySpec::Email)

      reloaded = reload!

      # Lookup is by name, so the stale object is an acceptable key...
      expect(registry.components_for(original).map(&:component_class))
        .to eq [RegistrySpec::Email]
      # ...but what comes back out is always the live constant.
      expect(registry.components_for(original).first.entity_class).to equal(reloaded)
    end

    it "treats a reloaded class as the same entity when detecting duplicates" do
      original = define_reloadable
      register(original, RegistrySpec::Email)

      reloaded = reload!

      expect { register(reloaded, RegistrySpec::Email) }
        .to raise_error(Rorecs::DuplicateComponent)
    end
  end

  describe "when a registered class no longer resolves" do
    # Decision: fail loudly. A dangling name means the registry has drifted out
    # of sync with the app. Silently dropping the entry would make the migration
    # generator emit an incomplete schema and delegation quietly stop working —
    # far worse than a NameError that names the missing constant. The legitimate
    # way to drop entries is #clear!, which the Railtie calls on every reload.

    before { RegistrySpec.const_set(:Doomed, Class.new) }

    after do
      RegistrySpec.send(:remove_const, :Doomed) if RegistrySpec.const_defined?(:Doomed, false)
    end

    it "raises NameError when resolving a component whose constant is gone" do
      register(RegistrySpec::User, RegistrySpec::Doomed)
      RegistrySpec.send(:remove_const, :Doomed)

      expect { registry.components_for(RegistrySpec::User).map(&:component_class) }
        .to raise_error(NameError, /Doomed/)
    end

    it "raises NameError when resolving an entity whose constant is gone" do
      register(RegistrySpec::Doomed, RegistrySpec::Email)
      RegistrySpec.send(:remove_const, :Doomed)

      expect { registry.entities_for(RegistrySpec::Email) }
        .to raise_error(NameError, /Doomed/)
    end

    it "still lists the declaration itself, because resolution is lazy" do
      register(RegistrySpec::User, RegistrySpec::Doomed)
      RegistrySpec.send(:remove_const, :Doomed)

      expect(registry.components_for(RegistrySpec::User).map(&:component_class_name))
        .to eq ["RegistrySpec::Doomed"]
    end
  end
end
