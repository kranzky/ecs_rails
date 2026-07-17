# frozen_string_literal: true

require_relative "generator_helper"
require "open3"
require "tmpdir"

# Every other spec in this directory runs after spec_helper.rb has required
# active_record and ecs_rails. That masks load-order bugs in the generator files
# themselves: a generator can reference a constant it never required and still
# pass, because something else happened to load it first.
#
# A real `rails g` in a host app would also have ActiveRecord loaded, so this is
# a latent fault rather than a user-visible one — but the generator files should
# stand on their own requires. This spec shells out to a clean Ruby process that
# loads ONLY the generator file, which is the only way to prove that.
RSpec.describe "generator load isolation" do
  # Each generator, and the constant a bare `invoke_all` must be able to reach.
  {
    "install" => "EcsRails::Generators::InstallGenerator",
    "component" => "EcsRails::Generators::ComponentGenerator"
  }.each do |name, const|
    it "loads #{name}_generator.rb without a pre-loaded ActiveRecord" do
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).inspect})
        require "rails/generators"
        require "generators/ecs_rails/#{name}/#{name}_generator"
        # Touch the constants the generator's migration machinery depends on.
        #{const}
        ActiveRecord::Migration
        ActiveRecord::VERSION::MAJOR
        puts "ok"
      RUBY

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)

      aggregate_failures do
        expect(stderr).to eq("")
        expect(status).to be_success
        expect(stdout.strip).to eq("ok")
      end
    end
  end

  # The end-to-end proof: a clean process that generates real files.
  it "generates the entities migration from a clean process" do
    Dir.mktmpdir("ecs_rails-isolation-") do |root|
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).inspect})
        require "rails/generators"
        require "generators/ecs_rails/install/install_generator"
        EcsRails::Generators::InstallGenerator.new(
          [], {}, destination_root: #{root.inspect}
        ).invoke_all
      RUBY

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)

      aggregate_failures do
        expect(stderr).to eq("")
        expect(status).to be_success
        expect(Dir.glob(File.join(root, "db/migrate/*_ecs_rails_create_entities.rb")).size).to eq(1)
      end
    end
  end

  # Attribute parsing is the part that breaks in isolation: GeneratedAttribute
  # .parse needs String#remove. Passing attributes here is the whole point — a
  # clean-process run with no attributes would not exercise the parser at all.
  it "generates a component migration WITH attributes from a clean process" do
    Dir.mktmpdir("ecs_rails-isolation-") do |root|
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).inspect})
        require "rails/generators"
        require "generators/ecs_rails/component/component_generator"
        EcsRails::Generators::ComponentGenerator.new(
          %w[Email address:string verified:boolean], {}, destination_root: #{root.inspect}
        ).invoke_all
      RUBY

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)
      migration = Dir.glob(File.join(root, "db/migrate/*_create_emails.rb")).first

      aggregate_failures do
        expect(stderr).to eq("")
        expect(status).to be_success
        expect(migration).not_to be_nil
        expect(File.read(migration.to_s, encoding: "UTF-8"))
          .to match(/t\.boolean :verified, default: false, null: false/)
      end
    end
  end
end
