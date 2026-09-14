# frozen_string_literal: true

# Only the orchestrator creates the database and supplies its exact name.
abort "Use the benchmark orchestrator" unless ENV["RAILS_ENV"] == "test" &&
  ENV.fetch("ECS_PERFORMANCE_DATABASE", "").match?(/\Aecs_performance_[0-9a-f]+\z/)
require_relative "../../config/environment"
require "json"
require "pg"
abort "Database does not belong to this run" unless ActiveRecord::Base.connection_db_config.database == ENV.fetch("ECS_PERFORMANCE_DATABASE")
ActiveRecord::Base.logger = nil
mode, output, *arguments = ARGV
if mode == "prepare"
  # Entity declarations inspect component columns, so install before loading them.
  ActiveRecord::Migration.verbose = false
  ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate
end
Rails.application.eager_load!
require_relative "models"
require_relative "checkout"
require_relative "schema"
require_relative "fixtures"
require_relative "workloads"
require_relative "verify"
require_relative "measurement"

result = case mode
when "prepare"
  PerformanceComparison::Schema.create
  installed = PerformanceComparison::Measurement.storage
  PerformanceComparison::Fixtures.load(Integer(arguments.fetch(0)))
  { installed: installed, populated: PerformanceComparison::Measurement.storage,
    schema: PerformanceComparison::Measurement.schema,
    versions: { ruby: RUBY_DESCRIPTION, rails: Rails.version,
                ecs_on_rails: EcsRails::VERSION, pg_gem: PG::VERSION,
                postgresql: ActiveRecord::Base.connection.select_value("SELECT version()") },
    database_settings: ActiveRecord::Base.connection.select_all("SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost', 'synchronous_commit', 'fsync', 'jit', 'max_parallel_workers_per_gather')").to_a }
when "verify"
  PerformanceComparison::Verify.run(Integer(arguments.fetch(0)))
when "reset"
  # No schema dump, seeds, demo reset task, or working database is touched.
  connection = ActiveRecord::Base.connection
  tables = connection.tables - %w[schema_migrations ar_internal_metadata]
  connection.execute("TRUNCATE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')}")
  PerformanceComparison::Fixtures.load(Integer(arguments.fetch(0)))
  { populated: PerformanceComparison::Measurement.storage }
when "measure"
  representation, name, warmups, samples = arguments
  raise "Unknown workload" unless PerformanceComparison::Workloads::NAMES.include?(name)
  raise "Unknown representation" unless %w[ecs plain].include?(representation)
  PerformanceComparison::Measurement.run(representation, name, warmups: Integer(warmups), samples: Integer(samples))
when "plans"
  %w[ecs plain].to_h { |representation| [representation, PerformanceComparison::Workloads.new(representation).plans] }
else
  abort "Unknown worker mode"
end
File.write(output, JSON.pretty_generate(result) + "\n")
