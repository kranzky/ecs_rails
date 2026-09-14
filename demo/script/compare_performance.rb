# frozen_string_literal: true

# Run from demo: bundle exec ruby script/compare_performance.rb --help
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pg"
require "securerandom"
require "tmpdir"
require "uri"
require "digest"

class PerformanceComparisonRunner
  def initialize
    @options = { sizes: [100, 1000, 5000], warmups: 3, samples: 20,
                 output: File.expand_path("../../tmp/ecs33-results.json", __dir__) }
    OptionParser.new do |parser|
      parser.banner = "Usage: bundle exec ruby script/compare_performance.rb [options]"
      parser.on("--sizes N,N,N", Array, "Product counts (at least 100)") { |values| @options[:sizes] = values.map { |value| Integer(value) } }
      parser.on("--warmups N", Integer) { |value| @options[:warmups] = value }
      parser.on("--samples N", Integer) { |value| @options[:samples] = value }
      parser.on("--output PATH") { |value| @options[:output] = File.expand_path(value) }
      parser.on("--smoke", "100 products, one warmup and two samples") { @options.merge!(sizes: [100], warmups: 1, samples: 2) }
      parser.on("-h", "--help") { puts parser; exit }
    end.parse!
    abort "Sizes must be >= 100; samples positive; warmups nonnegative" unless
      @options[:sizes].any? && @options[:sizes].all? { |size| size >= 100 } &&
      @options[:samples].positive? && @options[:warmups] >= 0
    @root = File.expand_path("..", __dir__)
    @admin_url = URI(ENV.fetch("DATABASE_URL", "postgresql:///postgres"))
    abort "DATABASE_URL must be a PostgreSQL URL" unless %w[postgres postgresql].include?(@admin_url.scheme)
    @database = nil
  end

  def run
    results = { format_version: 1, measured_at: Time.now.utc.iso8601,
                command: @options, source: source, host: host, sizes: [] }
    Dir.mktmpdir("ecs-performance-") do |directory|
      @directory = directory
      @options[:sizes].each_with_index do |size, index|
        create_database
        puts "Preparing and verifying #{size} products in #{@database}"
        prepared = worker("prepare", size)
        verified = worker("verify", size)
        reset = worker("reset", size)
        plans = worker("plans")
        measured = []
        # Alternate which representation goes first across sizes; every pair
        # shares the same database/server and each gets a fresh Ruby process.
        representations = index.even? ? %w[ecs plain] : %w[plain ecs]
        %w[catalogue detail preload_all preload_selected sweep checkout].each do |name|
          representations.each do |representation|
            puts "Measuring #{size} / #{name} / #{representation}"
            measured << worker("measure", representation, name, @options[:warmups], @options[:samples])
          end
        end
        results[:sizes] << { products: size, prepared: prepared, verification: verified,
                            measurement_start: reset, workloads: measured, plans: plans }
        FileUtils.mkdir_p(File.dirname(@options[:output]))
        File.write(@options[:output], JSON.pretty_generate(results) + "\n")
        drop_database
      end
    end
    puts "Verified results: #{@options[:output]}"
  ensure
    drop_database
  end

  private

  def create_database
    name = "ecs_performance_#{SecureRandom.hex(8)}"
    PG.connect(@admin_url.to_s) { |connection| connection.exec("CREATE DATABASE #{connection.quote_ident(name)}") }
    @database = name # Record ownership only after successful creation.
  end

  def drop_database
    return unless @database

    PG.connect(@admin_url.to_s) { |connection| connection.exec("DROP DATABASE #{connection.quote_ident(@database)}") }
    @database = nil
  end

  def worker(mode, *arguments)
    url = @admin_url.dup
    url.path = "/#{@database}"
    output = File.join(@directory, "#{mode}.json")
    environment = { "DATABASE_URL" => url.to_s, "RAILS_ENV" => "test", "DEMO_RESET_ENABLED" => "false",
                    "ECS_PERFORMANCE_DATABASE" => @database, "CI" => nil }
    log, status = Open3.capture2e(environment, RbConfig.ruby, "script/performance/worker.rb",
                                mode, output, *arguments.map(&:to_s), chdir: @root)
    raise "#{mode} failed:\n#{log}" unless status.success?

    JSON.parse(File.read(output))
  end

  def source
    paths = Dir.glob(File.join(@root, "script/performance/**/*")).select { |path| File.file?(path) }
    paths << __FILE__
    { commit: Open3.capture2("git", "rev-parse", "HEAD", chdir: @root).first.strip,
      benchmark_sha256: paths.sort.to_h { |path| [path.delete_prefix(@root + "/"), Digest::SHA256.file(path).hexdigest] },
      demo_lock_sha256: Digest::SHA256.file(File.join(@root, "Gemfile.lock")).hexdigest }
  end

  def host
    result = { platform: RUBY_PLATFORM, os: Open3.capture2("uname", "-sr").first.strip }
    if RUBY_PLATFORM.include?("darwin")
      %w[machdep.cpu.brand_string hw.memsize hw.logicalcpu].each do |key|
        result[key] = Open3.capture2("sysctl", "-n", key).first.strip
      end
    elsif File.exist?("/proc/cpuinfo")
      result[:cpu] = File.readlines("/proc/cpuinfo").find { |line| line.start_with?("model name") }&.strip
      result[:memory] = File.readlines("/proc/meminfo").first.strip
    end
    result
  end
end

require "time"
PerformanceComparisonRunner.new.run
