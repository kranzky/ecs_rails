# frozen_string_literal: true

# ECS-32: seed outside the timed process, then compare the previous and bounded
# systems on identical persisted vectors. Only an explicitly named benchmark
# test database may be changed. See docs/design/batched-indexer.md.
abort "Use RAILS_ENV=test" unless ENV["RAILS_ENV"] == "test"
require_relative "../config/environment"
require "digest"
require "json"

unless ActiveRecord::Base.connection_db_config.database.start_with?("ecs_indexer_bench_")
  abort "Use a dedicated ecs_indexer_bench_* database"
end

mode = ARGV.shift
if mode == "prepare"
  size = Integer(ARGV.fetch(0), 10)
  abort "Size must be positive" unless size.positive?
  ApplicationEntity.delete_all
  size.times.each_slice(100) do |indices|
    entities = []
    texts = []
    vectors = []
    indices.each do |index|
      id = SecureRandom.uuid
      model = index % 5 == 0 ? "groups" : (index.even? ? "posts" : "products")
      entities << { id: id, model: model, created_at: Time.utc(2026, 1, 1) }
      %w[body summary title].each do |slot|
        texts << { entity_id: id, slot: slot, value: ("#{slot} owner#{index} search words " * 80) }
      end
      vectors << { entity_id: id, slot: "" } unless model == "groups"
    end
    ApplicationEntity.insert_all!(entities)
    Text.insert_all!(texts)
    SearchVector.insert_all!(vectors)
  end
  puts JSON.generate(prepared_owners: size, text_rows: Text.count, vectors: SearchVector.count)
  exit
end

# ECS-39: candidate write paths, measured before one was chosen for
# Demo::Indexer. Each shares the indexer's batched discovery and differs only
# in how a batch's documents reach search_vectors. See
# docs/design/batched-indexer.md.
module IndexerCandidates
  module_function

  # Batches of eligible owners as { entity_id => document text }, built the
  # way Demo::Indexer builds them: slot order, nils omitted, joined by spaces.
  def each_batch(batch_size)
    ApplicationEntity.where(id: Text.select(:entity_id)).find_in_batches(batch_size: batch_size) do |entities|
      eligible = entities.select { |entity| entity.class.components.include?(SearchVector) }
      next if eligible.empty?

      values = Text.where(entity_id: eligible.map(&:id)).order(:slot).pluck(:entity_id, :value).group_by(&:first)
      yield eligible.to_h { |entity| [entity.id, values.fetch(entity.id, []).map(&:last).compact.join(" ")] }
    end
  end

  # Today's reindex! per owner, unchanged, but one transaction per batch: a
  # single commit instead of one per statement.
  def batch_transaction(batch_size)
    count = 0
    each_batch(batch_size) do |documents|
      vectors = SearchVector.where(entity_id: documents.keys, slot: "").index_by(&:entity_id)
      SearchVector.transaction do
        documents.each do |entity_id, text|
          (vectors[entity_id] || SearchVector.new(entity_id: entity_id)).reindex!(text)
          count += 1
        end
      end
    end
    count
  end

  # One UPDATE per owner, inserting a vector first when it is missing; no reload.
  def no_reload(batch_size)
    count = 0
    each_batch(batch_size) do |documents|
      documents.each do |entity_id, text|
        scope = SearchVector.where(entity_id: entity_id, slot: "")
        scope.insert_all([{ entity_id: entity_id, slot: "" }]) unless scope.exists?
        scope.update_all(["document = to_tsvector('simple', ?)", text])
        count += 1
      end
    end
    count
  end

  # Per batch: insert missing vectors, then one UPDATE ... FROM unnest.
  def update_from(batch_size)
    count = 0
    each_batch(batch_size) do |documents|
      present = SearchVector.where(entity_id: documents.keys, slot: "").pluck(:entity_id)
      missing = documents.keys - present
      SearchVector.insert_all(missing.map { |entity_id| { entity_id: entity_id, slot: "" } }) if missing.any?
      SearchVector.connection.exec_update(SearchVector.sanitize_sql_array([<<~SQL, documents.keys, documents.values]))
        UPDATE search_vectors SET document = to_tsvector('simple', batch.text)
        FROM unnest(ARRAY[?]::uuid[], ARRAY[?]::text[]) AS batch(entity_id, text)
        WHERE search_vectors.entity_id = batch.entity_id AND search_vectors.slot = ''
      SQL
      count += documents.size
    end
    count
  end

  # Per batch: one INSERT ... ON CONFLICT DO UPDATE.
  def upsert(batch_size)
    count = 0
    each_batch(batch_size) do |documents|
      now = Time.current
      SearchVector.connection.exec_update(SearchVector.sanitize_sql_array([<<~SQL, now, now, documents.keys, documents.values]))
        INSERT INTO search_vectors (entity_id, slot, document, created_at, updated_at)
        SELECT batch.entity_id, '', to_tsvector('simple', batch.text), ?, ?
        FROM unnest(ARRAY[?]::uuid[], ARRAY[?]::text[]) AS batch(entity_id, text)
        ON CONFLICT (entity_id, slot) DO UPDATE SET document = EXCLUDED.document
      SQL
      count += documents.size
    end
    count
  end
end

CANDIDATES = %w[batch_transaction no_reload update_from upsert].freeze
unless %w[baseline batched].include?(mode) || CANDIDATES.include?(mode)
  abort "Mode must be prepare, baseline, batched or one of #{CANDIDATES.join(', ')}"
end
batch_size = Integer(ENV.fetch("BATCH_SIZE", "100"), 10)
# Resolve schema metadata before counting SQL. Each mode still gets a fresh
# Ruby process, so /usr/bin/time includes the same Rails boot overhead.
[ApplicationEntity, Text, SearchVector].each(&:column_names)
queries = Hash.new(0)
listener = lambda do |*args|
  payload = args.last
  next if payload[:name] == "SCHEMA" || payload[:cached]

  sql = payload[:sql]
  queries[:total] += 1
  if sql.start_with?("SELECT")
    if sql.include?('FROM "entities"')
      queries[:owner_reads] += 1
    elsif sql.include?('FROM "texts"')
      queries[:text_reads] += 1
    elsif sql.include?('FROM "search_vectors"')
      queries[:vector_reads] += 1
    end
  elsif sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/)
    queries[:writes] += 1
  end
end

GC.start
allocated_before = GC.stat(:total_allocated_objects)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
indexed = nil
ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
  if CANDIDATES.include?(mode)
    indexed = IndexerCandidates.public_send(mode, batch_size)
  elsif mode == "baseline"
    # The previous implementation, retained only as the measurement baseline.
    indexed = Text.order(:slot).group_by(&:entity_id).sum do |entity_id, texts|
      entity = ApplicationEntity.find(entity_id)
      next 0 unless entity.class.components.include?(SearchVector)

      entity.search_vector.reindex!(*texts.map(&:value))
      1
    end
  else
    indexed = Demo::Indexer.call(batch_size: batch_size)
  end
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
allocated = GC.stat(:total_allocated_objects) - allocated_before
# Stream the checksum too; measurement must not group every document after
# proving that the indexer itself no longer does so.
digest = Digest::SHA256.new
SearchVector.where(slot: "").find_in_batches(batch_size: 100) do |vectors|
  vectors.each do |vector|
    digest.update(vector.entity_id).update(vector.document.to_s)
  end
end
puts JSON.generate(mode: mode, ruby: RUBY_VERSION, rails: Rails.version,
                   owners: ApplicationEntity.count, texts: Text.count, indexed: indexed,
                   batch_size: batch_size, seconds: elapsed.round(3), allocated_objects: allocated,
                   queries: queries, document_sha256: digest.hexdigest)
