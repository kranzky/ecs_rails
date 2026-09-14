# frozen_string_literal: true

# ECS-30: run through installed .gem files, real generators, migrations and
# rendered Rails requests. Every database and directory is owned by this run.
require "bundler"
require "fileutils"
require "json"
require "open3"
require "pg"
require "rubygems/package"
require "securerandom"
require "shellwords"
require "tmpdir"
require "uri"

class PackageSmoke
  def initialize
    @gem_root = File.expand_path("..", __dir__)
    @fixtures = File.join(__dir__, "package_smoke")
    @rails_version = Gem.loaded_specs.fetch("railties").version.to_s
    @gem_paths = (Gem.path + Gem.loaded_specs.values.map(&:base_dir)).uniq
    @database_url = URI(ENV.fetch("DATABASE_URL"))
    @databases = []
  end

  def run
    Dir.mktmpdir("ecs-rails-package-") do |directory|
      @directory = directory
      @candidate_home = File.join(directory, "candidate_gems")
      @legacy_home = File.join(directory, "legacy_gems")
      package = File.join(directory, "candidate.gem")
      Dir.chdir(@gem_root) do
        spec = Gem::Specification.load("ecs_on_rails.gemspec")
        @candidate_version = spec.version.to_s
        Gem::Package.build(spec, false, false, package)
      end
      install(package, @candidate_home)
      fresh_install
      legacy_upgrade
    end
    puts "Package smoke passed: Ruby #{RUBY_VERSION}, Rails #{@rails_version}."
  ensure
    @databases.each do |name|
      PG.connect(@database_url.to_s) do |connection|
        connection.exec("DROP DATABASE #{connection.quote_ident(name)}")
      end
    end
  end

  private

  def command(*arguments, chdir:, gem_home: @candidate_home, database: nil, preparing: false)
    environment = {
      "GEM_HOME" => gem_home,
      "GEM_PATH" => ([gem_home] + @gem_paths).join(File::PATH_SEPARATOR),
      "BUNDLE_PATH" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_FROZEN" => nil,
      "BUNDLE_DEPLOYMENT" => nil, "BUNDLE_APP_CONFIG" => nil,
      "BUNDLE_IGNORE_CONFIG" => "1", "BUNDLE_WITHOUT" => nil,
      "RAILS_ENV" => "test", "ECS_SMOKE_GEM_HOME" => gem_home,
      "ECS_SMOKE_PREPARING" => preparing ? "1" : nil,
      "DATABASE_URL" => database
    }
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e(environment, *arguments, chdir: chdir)
    end
    raise "#{arguments.join(' ')} failed:\n#{output}" unless status.success?

    puts output
    output
  end

  def install(package, home)
    command(RbConfig.ruby, "-S", "gem", "install", "--local", "--ignore-dependencies",
            "--no-document", "--install-dir", home, package, chdir: @directory, gem_home: home)
  end

  def database(label)
    name = "ecs_rails_package_#{label}_#{SecureRandom.hex(6)}"
    PG.connect(@database_url.to_s) do |connection|
      connection.exec("CREATE DATABASE #{connection.quote_ident(name)}")
    end
    @databases << name
    url = @database_url.dup
    url.path = "/#{name}"
    url.to_s
  end

  def application(name, version:, home:)
    path = File.join(@directory, name)
    command(RbConfig.ruby, "-e", "gem 'railties', ARGV.shift; load Gem.bin_path('railties', 'rails')",
            @rails_version, "new", path, "--minimal", "--skip-bundle", "--skip-git",
            "--skip-bootsnap", "--skip-asset-pipeline", "--skip-javascript", "--database=postgresql", chdir: @directory, gem_home: home)
    # Generators must create the new classes before the upgraded app can load
    # them. Final runners boot with eager loading on, independent of CI defaults.
    File.open(File.join(path, "config/environments/test.rb"), "a") do |file|
      file.puts <<~RUBY

        Rails.application.configure do
          config.eager_load = ENV["ECS_SMOKE_PREPARING"] != "1"
        end
      RUBY
    end
    File.write(File.join(path, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      gem "rails", "= #{@rails_version}"
      gem "ecs_on_rails", "= #{version}"
      gem "pg", "~> 1.5"
      gem "bcrypt", "~> 3.1"
    GEMFILE
    command(RbConfig.ruby, "-S", "bundle", "install", "--local", chdir: path, gem_home: home)
    path
  end

  def rails(path, database, *arguments, home: @candidate_home)
    command(RbConfig.ruby, "bin/rails", *arguments,
            chdir: path, gem_home: home, database: database,
            preparing: ["generate", "db:create", "db:migrate"].include?(arguments.first))
  end

  def write(path, relative, contents)
    target = File.join(path, relative)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, contents)
  end

  def fixture(path, name)
    write(path, "script/#{name}.rb", File.read(File.join(@fixtures, "#{name}.rb")))
  end

  # Marked README blocks are the tutorial's source, not copies maintained in a
  # fixture. Run commands as argument arrays so documentation is never a shell
  # program, and fail if a required block disappears.
  def readme_commands(path, url, section, name)
    marker = "#{section}:commands #{name}"
    blocks = File.read(File.join(@gem_root, "README.md")).scan(/<!-- #{Regexp.escape(marker)} -->\n```sh\n(.*?)```/m)
    raise "Expected one README block: #{marker}" unless blocks.size == 1

    blocks.first.first.lines.reject { |line| line.strip.empty? }.each do |line|
      executable, *arguments = Shellwords.split(line)
      raise "Expected bin/rails in #{marker}" unless executable == "bin/rails"

      rails(path, url, *arguments)
    end
  end

  def readme_files(path, section)
    blocks = File.read(File.join(@gem_root, "README.md")).scan(/<!-- #{section}:file ([\w\/.]+) -->\n```\w+\n(.*?)```/m)
    raise "Missing README files for #{section}" if blocks.empty?

    blocks.each { |relative, contents| write(path, relative, contents) }
  end

  def fresh_install
    url = database("fresh")
    path = application("fresh", version: @candidate_version, home: @candidate_home)
    readme_commands(path, url, "quickstart", "install")
    readme_files(path, "quickstart")
    readme_commands(path, url, "quickstart", "run")
    fixture(path, "fresh")
    rails(path, url, "runner", "script/fresh.rb")
    before = Dir.glob(File.join(path, "db/migrate/*"))
    readme_commands(path, url, "upgrade", "generate")
    raise "Current package generated another migration" unless Dir.glob(File.join(path, "db/migrate/*")) == before

    readme_commands(path, url, "bespoke", "install")
    readme_files(path, "bespoke")
    readme_commands(path, url, "bespoke", "run")
    fixture(path, "bespoke")
    rails(path, url, "runner", "script/bespoke.rb")
  end

  def legacy_upgrade
    command(RbConfig.ruby, "-S", "gem", "fetch", "ecs_on_rails", "--version", "0.2.2",
            chdir: @directory, gem_home: @legacy_home)
    install(File.join(@directory, "ecs_on_rails-0.2.2.gem"), @legacy_home)
    url = database("upgrade")
    path = application("upgrade", version: "0.2.2", home: @legacy_home)
    rails(path, url, "generate", "ecs_rails:install", home: @legacy_home)
    rails(path, url, "generate", "ecs_rails:component", "Handle", "value:string", home: @legacy_home)
    rails(path, url, "generate", "ecs_rails:component", "Moderator", home: @legacy_home)
    rails(path, url, "generate", "ecs_rails:relationship", "Memo", "author:Member", home: @legacy_home)
    rails(path, url, "db:migrate", home: @legacy_home)
    write(path, "app/entities/member.rb", "class Member < ApplicationEntity\n  component Handle\n  component Moderator\nend\n")
    write(path, "app/entities/memo.rb", "class Memo < ApplicationEntity\n  relates_to :author, Member\nend\n")
    fixture(path, "legacy")
    rails(path, url, "runner", "script/legacy.rb", home: @legacy_home)

    # Published and candidate packages currently share the pre-release version
    # number. Separate GEM_HOMEs and fresh processes make the switch explicit.
    gemfile = File.join(path, "Gemfile")
    File.write(gemfile, File.read(gemfile).sub('gem "ecs_on_rails", "= 0.2.2"', "gem \"ecs_on_rails\", \"= #{@candidate_version}\""))
    command(RbConfig.ruby, "-S", "bundle", "update", "ecs_on_rails", "--local", chdir: path)
    readme_commands(path, url, "upgrade", "generate")
    readme_commands(path, url, "upgrade", "migrate")
    write(path, "app/entities/member.rb", "class Member < ApplicationEntity\n  component Handle\n  marker :moderator\nend\n")
    File.delete(File.join(path, "app/entities/components/moderator.rb"))
    fixture(path, "upgraded")
    rails(path, url, "runner", "script/upgraded.rb")
    before = Dir.glob(File.join(path, "db/migrate/*"))
    readme_commands(path, url, "upgrade", "verify")
    raise "Repeated upgrade generated another migration" unless Dir.glob(File.join(path, "db/migrate/*")) == before
  end
end

PackageSmoke.new.run
