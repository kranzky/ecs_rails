# frozen_string_literal: true

require_relative "generator_helper"

# RFC-0008 / ECS-11: generate readable references without adding storage. Errors
# must precede writes, and ordinary Thor collision/reversal behavior must survive.
RSpec.describe EcsRails::Generators::EntityGenerator, type: :generator do
  # Other feature specs define Person as a fixture. This destination represents
  # a fresh app; restore the existing constant automatically after each example.
  before { hide_const("Person") }

  it "writes the exact Person example and no other files" do
    run_generator %w[Person name email mobile:phone work:phone home:address]
    expect(file("app/entities/person.rb")).to eq <<~RUBY
      # frozen_string_literal: true

      class Person < ApplicationEntity
        component Name
        component Email
        component Phone, prefix: :mobile
        component Phone, prefix: :work
        component Address, prefix: :home
      end
    RUBY
    expect(Dir.glob("#{destination_root}/**/*").select { |path| File.file?(path) }.size).to eq(1)
  end

  it "can generate an empty identity class" do
    run_generator %w[Person]
    expect(file("app/entities/person.rb")).to include("class Person < ApplicationEntity\nend")
  end

  it "respects the configured path and namespaced entity names" do
    EcsRails.config.entities_path = "app/models"
    run_generator %w[People/Person Name home:Address avatar:Image]
    expect(file("app/models/people/person.rb")).to include("class People::Person < ApplicationEntity", "component ::Name", "component ::Address, prefix: :home", "component ::Image, prefix: :avatar")
  end

  it "resolves slash and Ruby constant namespaces" do
    stub_const("Directory", Module.new)
    stub_const("Directory::Email", Class.new(ApplicationComponent))
    run_generator %w[Person directory/email work:Directory::Email]
    expect(file("app/entities/person.rb")).to include("component Directory::Email\n", "component Directory::Email, prefix: :work")
  end

  it "resolves renamed existing component classes" do
    stub_const("ContactEmail", Class.new(ApplicationComponent))
    run_generator %w[Person contact_email]
    expect(file("app/entities/person.rb")).to include("component ContactEmail")
  end

  [%w[Person email Email], %w[Person home:address home:Address]].each do |arguments|
    it "rejects duplicate references #{arguments.drop(1).join(' ')} before writing" do
      expect { run_generator(arguments) }.to raise_error(Rails::Generators::Error, /Duplicate component/)
      expect(file?("app/entities/person.rb")).to be(false)
    end
  end

  %w[home: Home:address home:address:extra ../email email;exit].each do |reference|
    it "rejects malformed reference #{reference.inspect} before writing" do
      expect { run_generator ["Person", "name", reference] }.to raise_error(Rails::Generators::Error, /Invalid component reference/)
      expect(file?("app/entities/person.rb")).to be(false)
    end
  end

  %w[../Person Person;exit 123person Person/].each do |entity_name|
    it "rejects invalid entity name #{entity_name.inspect}" do
      expect { run_generator [entity_name] }.to raise_error(Rails::Generators::Error, /Invalid entity name/)
    end
  end

  it "explains missing catalogue and bespoke references without writing" do
    expect { run_generator %w[Person name missing_component] }
      .to raise_error(Rails::Generators::Error, /MissingComponent.*ecs_rails:install.*--sets.*ecs_rails:component/m)
    expect(file?("app/entities/person.rb")).to be(false)
  end

  %w[String ApplicationComponent EcsRails::Catalogue::Email].each do |reference|
    it "rejects non-concrete component #{reference}" do
      expect { run_generator ["Person", reference] }.to raise_error(Rails::Generators::Error, /existing concrete/)
    end
  end

  it "explains a missing installation" do
    hide_const("ApplicationEntity")
    expect { run_generator %w[Person name] }.to raise_error(Rails::Generators::Error, /ecs_rails:install/)
  end

  it "protects an unrelated existing constant" do
    expect { run_generator %w[String] }.to raise_error(Rails::Generators::Error, /already used|reserved/)
  end

  it "preserves a conflicting file with --skip and replaces it with --force" do
    run_generator %w[Person name]
    original = file("app/entities/person.rb")
    run_generator %w[Person email --skip]
    expect(file("app/entities/person.rb")).to eq(original)
    run_generator %w[Person email --force]
    expect(file("app/entities/person.rb")).to include("component Email")
    expect(file("app/entities/person.rb")).not_to include("component Name")
  end

  it "supports pretend without creating a file" do
    run_generator %w[Person name --pretend]
    expect(file?("app/entities/person.rb")).to be(false)
  end

  it "reverses generation even when the old reference no longer exists" do
    run_generator %w[Person name]
    run_generator %w[Person missing_component], behavior: :revoke
    expect(file?("app/entities/person.rb")).to be(false)
  end
end
