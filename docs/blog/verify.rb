# frozen_string_literal: true

# Runs a blog post's code against the published gem (ECS-20), the way a reader
# would: a new Rails app in a temporary directory, the post's shell commands in
# order, its files written where it says, and its console session replayed with
# every `# => value` comment checked. A post is only "verified against the
# release" while this passes. The video's shooting script (ECS-10) uses the
# same markers, so it rehearses the recording the same way.
#
#   ruby docs/blog/verify.rb docs/blog/the-last-migration.md
#   ruby docs/blog/verify.rb docs/video/compose-a-contacts-app.md
#
# Needs Ruby >= 3.2 with the `rails` gem installed, network access to
# RubyGems, and a PostgreSQL role that may create databases. DATABASE_URL
# (default postgresql:///postgres) names the server; the app's database gets
# a unique name and is dropped afterwards.
#
# The post marks what runs with HTML comments, which Markdown renderers hide:
#
#   <!-- verify:commands -->      the next ```sh block runs in bash, in order
#   <!-- verify:sql -->           the next ```sql block is typed into
#                                 `bin/rails dbconsole` (psql, no psqlrc)
#   <!-- verify:output -->        the next ```text block must equal the
#                                 previous commands or sql block's output,
#                                 word for word (14-digit migration
#                                 timestamps and spacing aside)
#   <!-- verify:output columns --> the same, for output a terminal lays out
#                                 in columns (`ls`): compared as a set of
#                                 words, since columns read down, not across
#   <!-- verify:file PATH -->     the next ```ruby block is written to PATH,
#                                 relative to the app
#   <!-- verify:console -->       the next ```ruby block is part of one
#                                 console session, replayed with
#                                 `bin/rails runner` before the next commands
#                                 or sql block (or at the end)
#
# Unmarked blocks (SQL logs, psql output, excerpts) are illustration and are
# not run. A `# => value` check compares `value` with the expression's
# #inspect, so it belongs on one-line expressions, never on an assignment.
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"
require "uri"

class BlogVerifier
  MARKER = /^<!-- verify:(commands|sql|output|console|file)(?: (\S+))? -->\n```(\w+)\n(.*?)^```$/m
  CHECK = /\A(\s*)(.+?)\s+# => (.+)\z/

  def initialize(post)
    @post = File.expand_path(post)
    @text = File.read(@post)
    server = URI(ENV.fetch("DATABASE_URL", "postgresql:///postgres"))
    server.path = "/ecs_blog_#{SecureRandom.hex(6)}"
    @database_url = server.to_s
    @console = []
    @checks = 0
  end

  def run
    Dir.mktmpdir("ecs-rails-blog-") do |directory|
      @directory = directory
      blocks.each { |kind, argument, language, body, line| step(kind, argument, language, body, line) }
      replay_console
      bash("bin/rails zeitwerk:check")
    ensure
      drop_database
    end
    puts "Verified #{File.basename(@post)}: #{@checks} console checks passed."
  end

  private

  # Each marked block with the line it starts on, for error messages.
  def blocks
    @text.to_enum(:scan, MARKER).map do
      match = Regexp.last_match
      [*match.captures, @text[0...match.begin(0)].count("\n") + 2]
    end
  end

  def step(kind, argument, language, body, line)
    case kind
    when "commands"
      expect_language("sh", language, line)
      replay_console
      @last_output = bash(body)
    when "sql"
      expect_language("sql", language, line)
      replay_console
      @last_output = bash("bin/rails dbconsole <<'SQL'\n#{body}SQL")
    when "output"
      expect_language("text", language, line)
      expected, actual = normalise(body), normalise(@last_output)
      expected, actual = expected.sort, actual.sort if argument == "columns"
      unless expected == actual
        abort "Line #{line}: output differs.\nExpected:\n#{body}\nActual:\n#{@last_output}"
      end
    when "file"
      expect_language("ruby", language, line)
      target = File.join(@cwd, argument)
      check_generated(target, body, line) if File.exist?(target)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, body)
    when "console"
      expect_language("ruby", language, line)
      body.lines.each_with_index { |source, offset| @console << [source.chomp, line + offset] }
    end
  end

  # A post may show a generated file, then hand-edit it to add relationships
  # and markers. The edit keeps every declaration the generator wrote, so the
  # generated `component` lines must be exactly the post's.
  def check_generated(target, body, line)
    generated = File.read(target).lines.grep(/^  component /)
    return if generated == body.lines.grep(/^  component /)

    abort "Line #{line}: the post's components differ from the generated #{File.basename(target)}:\n#{generated.join}"
  end

  def expect_language(expected, actual, line)
    abort "Line #{line}: a verify block must be ```#{expected}, not ```#{actual}" unless expected == actual
  end

  # Runs one shell block with bash's strict flags. A block may `cd`; the next
  # one starts where it finished, as it would for a reader in one terminal.
  def bash(script)
    @cwd ||= @directory
    state = File.join(@directory, ".cwd")
    # PSQLRC: a personal psqlrc (\timing, a pager) would change the output.
    environment = { "DATABASE_URL" => @database_url, "BUNDLE_GEMFILE" => nil, "PSQLRC" => File::NULL }
    output, status = Open3.capture2e(environment, "bash", "-euo", "pipefail", "-c", "#{script}\npwd > #{state}",
                                     chdir: @cwd)
    abort "Failed:\n#{script}\n#{output}" unless status.success?

    @cwd = File.read(state).strip
    output
  end

  # The console session as one runner script: `expr # => value` becomes a check.
  def replay_console
    return if @console.empty?

    script = +<<~RUBY
      def __expect(line, expected)
        actual = yield.inspect
        abort "Line \#{line} of the post: expected \#{expected}, got \#{actual}" unless actual == expected
      end
    RUBY
    @console.each do |source, line|
      if (match = CHECK.match(source))
        indent, expression, expected = match.captures
        script << "#{indent}__expect(#{line}, #{expected.strip.dump}) { #{expression} }\n"
        @checks += 1
      else
        script << "#{source}\n"
      end
    end
    @console = []
    File.write(File.join(@cwd, "tmp/blog_console.rb"), script)
    bash("bin/rails runner tmp/blog_console.rb")
  end

  # Compared word by word: a terminal lays `ls` out in columns and psql pads
  # its tables, and neither layout is what a reader needs checked.
  def normalise(output)
    output.to_s.gsub(/\d{14}/, "<timestamp>").split
  end

  def drop_database
    return unless @cwd && File.exist?(File.join(@cwd, "bin/rails"))

    Open3.capture2e({ "DATABASE_URL" => @database_url, "DISABLE_DATABASE_ENVIRONMENT_CHECK" => "1" },
                    "bin/rails", "db:drop", chdir: @cwd)
  end
end

abort "Usage: ruby #{$PROGRAM_NAME} POST.md" unless ARGV.size == 1
BlogVerifier.new(ARGV.first).run
