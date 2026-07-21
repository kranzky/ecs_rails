# frozen_string_literal: true

# Harness for the RFC-0008 generator specs.
#
# Deliberately NOT ammeter. Ammeter pulls in rspec-rails, which expects a real
# Rails.application and installs its own transactional-fixture hooks — this gem
# has no host app, and those hooks would collide with spec_helper.rb's own
# `config.around` transaction. Rails' own Rails::Generators::TestCase is
# minitest-based, but its substance is only "instantiate the generator, run
# invoke_all against a tmp destination_root, then look at the files". That is
# reproduced here, so the specs run the real generator and inspect real output.
#
# spec_helper.rb is loaded first (via .rspec's --require spec_helper) and is not
# Rails-aware; this file adds the Rails generator machinery on top of it without
# modifying it.

require "rails/generators"
require "rails/generators/active_record"
require "fileutils"
require "stringio"
require "tmpdir"

require_relative "../../lib/generators/ecs_rails/install/install_generator"
require_relative "../../lib/generators/ecs_rails/component/component_generator"
require_relative "../../lib/generators/ecs_rails/relationship/relationship_generator"

# Shared behaviour for generator examples. Include with `include GeneratorHelper`
# or rely on the `type: :generator` metadata hook configured below.
module GeneratorHelper
  # A throwaway destination for the generator to write into. One per example, so
  # examples cannot see each other's output.
  #
  # Deliberately under Dir.tmpdir rather than gem/tmp: the repo's .gitignore
  # ignores /tmp at the root only, so a destination inside the gem would show up
  # as untracked junk on any run that failed before cleanup.
  def destination_root
    @destination_root ||= Dir.mktmpdir("ecs_rails-generator-")
  end

  # Runs the generator under test (described_class) exactly as Rails would.
  # Returns the generator instance. Thor's chatter is swallowed.
  def run_generator(args = [], config = {})
    generator = described_class.new(
      args, {}, config.merge(destination_root: destination_root)
    )
    silence_stream { generator.invoke_all }
    generator
  end

  # Contents of a generated file, relative to destination_root.
  #
  # Read as UTF-8 explicitly rather than trusting Encoding.default_external,
  # which is US-ASCII under a bare LANG. Generated files are UTF-8 (the comments
  # contain em-dashes), and a mismatch surfaces as "invalid byte sequence in
  # US-ASCII" from the matcher rather than as anything informative.
  def file(relative_path)
    File.read(File.join(destination_root, relative_path), encoding: "UTF-8")
  end

  def file?(relative_path)
    File.exist?(File.join(destination_root, relative_path))
  end

  # Absolute paths of generated migrations matching a suffix, e.g.
  # migration_paths("create_emails") => [".../db/migrate/20260717000000_create_emails.rb"]
  def migration_paths(suffix)
    Dir.glob(File.join(destination_root, "db", "migrate", "*_#{suffix}.rb")).sort
  end

  # Contents of the single migration matching `suffix`. Fails loudly if there
  # isn't exactly one — a silently-missing migration must not read as a pass.
  def migration(suffix)
    paths = migration_paths(suffix)
    raise "expected exactly one *_#{suffix}.rb migration, found #{paths.size}" unless paths.size == 1

    File.read(paths.first, encoding: "UTF-8")
  end

  def silence_stream
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def cleanup_destination_root
    FileUtils.rm_rf(@destination_root) if @destination_root
  end
end

RSpec.configure do |config|
  config.include GeneratorHelper, type: :generator
  config.after(type: :generator) { cleanup_destination_root }
end
