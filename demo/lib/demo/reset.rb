# frozen_string_literal: true

module Demo
  # Wipes all application data and reloads the demo seed. TRUNCATE ... CASCADE
  # clears the entities table and every component/relationship table regardless
  # of foreign keys, in one statement. Fast — the seed is tiny.
  module Reset
    module_function

    PROTECTED = %w[schema_migrations ar_internal_metadata].freeze

    def call
      conn = ActiveRecord::Base.connection
      tables = conn.tables - PROTECTED
      return if tables.empty?

      quoted = tables.map { |t| conn.quote_table_name(t) }.join(", ")
      conn.execute("TRUNCATE #{quoted} RESTART IDENTITY CASCADE")
      Demo::Seed.call
    end
  end
end
