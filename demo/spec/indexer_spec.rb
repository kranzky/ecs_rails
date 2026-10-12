# frozen_string_literal: true

require "rails_helper"

# ECS-32: whole-entity boundaries preserve ordered text documents while memory
# and owner discovery stay bounded. The system must continue deciding from
# component declarations rather than a list of concrete entity classes.
# ECS-39: each batch is written by one INSERT ... ON CONFLICT, so these also
# pin what that bulk path keeps (documents, vector ids, default slot, the
# untouched updated_at) and what it skips (SearchVector models, and so their
# callbacks). If they change, docs/design/batched-indexer.md must too.
RSpec.describe Demo::Indexer do
  include ActiveSupport::Testing::TimeHelpers

  before { ApplicationEntity.delete_all }

  def expected_document(values)
    sql = ActiveRecord::Base.sanitize_sql_array(["SELECT to_tsvector('simple', ?)::text", values.compact.join(" ")])
    ActiveRecord::Base.connection.select_value(sql)
  end

  def documents
    SearchVector.where(slot: "").pluck(:entity_id, Arel.sql("document::text")).to_h
  end

  it "indexes complete slot-ordered documents across uneven entity batches" do
    owners = Array.new(5) do |index|
      owner = (index.even? ? Post : Product).create!
      # Insert in reverse order: SQL slot order, not insertion order, defines
      # positions in the resulting tsvector (phrase searches depend on these).
      %w[zeta title middle body alpha].each do |slot|
        Text.create!(entity: owner, slot: slot, value: "#{slot} token#{index}")
      end
      owner
    end
    existing = owners.first.search_vector
    existing.reindex!("obsolete")
    identity = existing.id

    expect(described_class.call(batch_size: 2)).to eq 5
    expected = owners.to_h do |owner|
      [owner.id, expected_document(Text.where(entity_id: owner.id).order(:slot).pluck(:value))]
    end
    expect(documents).to eq expected
    expect(owners.first.reload.search_vector.id).to eq identity
    ids = SearchVector.pluck(:entity_id, :id).to_h
    expect(described_class.call(batch_size: 1)).to eq 5
    expect(documents).to eq expected
    expect(SearchVector.pluck(:entity_id, :id).to_h).to eq ids
  end

  it "keeps one owner's many text slots together even with a one-owner batch" do
    owner = Product.create!
    12.times { |index| Text.create!(entity: owner, slot: "part_#{index.to_s.rjust(2, '0')}", value: "word#{index}") }
    Text.create!(entity: owner, slot: "empty", value: nil)

    expect(described_class.call(batch_size: 1)).to eq 1
    expect(documents.fetch(owner.id)).to eq expected_document((0...12).map { |index| "word#{index}" })
  end

  it "skips undeclared vectors and owners without texts, retaining their data" do
    group = Group.create!(name: "Do not index")
    stray = SearchVector.create!(entity: group)
    stray.reindex!("keep group vector")
    no_text = Post.create!
    no_text.search_vector.reindex!("keep old document")
    eligible = Product.create!(title: "Included")
    before = documents

    expect(described_class.call(batch_size: 1)).to eq 1
    expect(documents).to include(before)
    expect(documents.fetch(eligible.id)).to eq expected_document(["Included"])
    expect(SearchVector.count).to eq 3
  end

  it "discovers declaration eligibility for an unfamiliar entity subclass" do
    stub_const("IndexerEntry", Class.new(ApplicationEntity))
    IndexerEntry.class_eval do
      component Text, prefix: :headline
      component SearchVector
    end
    entry = IndexerEntry.create!(headline: "Unfamiliar searchable owner")

    expect(described_class.call(batch_size: 1)).to eq 1
    expect(documents.fetch(entry.id)).to eq expected_document([entry.headline])
  end

  it "returns zero for an empty database" do
    expect(described_class.call(batch_size: 2)).to eq 0
  end

  it "rejects invalid batch sizes before doing database work" do
    [0, -1, nil, "2", 1.5].each do |size|
      expect { described_class.call(batch_size: size) }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  it "discovers owners in batches and restricts text reads to each batch" do
    5.times { |index| Post.create!(title: "Title #{index}", body: "Body #{index}") }
    queries = []
    callback = ->(*args) { payload = args.last; queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.call(batch_size: 2) }

    owner_reads = queries.grep(/SELECT .*FROM "entities"/)
    text_reads = queries.grep(/SELECT .*FROM "texts"/).reject { |sql| sql.include?('FROM "entities"') }
    expect(owner_reads.size).to eq 3
    expect(owner_reads).to all(include("LIMIT"))
    expect(text_reads.size).to eq 3
    expect(text_reads).to all(include('WHERE "texts"."entity_id"'))
    expect(queries.grep(/FROM "search_vectors"/)).to be_empty
    expect(queries.grep(/\AINSERT INTO "search_vectors"/).size).to eq 3
    expect(queries.grep(/\A\s*(UPDATE|DELETE)/)).to be_empty
  end

  it "writes once per batch however many owners it holds" do
    writes_for = lambda do
      count = 0
      callback = ->(*args) { count += 1 if args.last[:sql].start_with?("INSERT INTO \"search_vectors\"") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.call(batch_size: 4) }
      count
    end
    4.times { |index| Post.create!(title: "First #{index}") }
    expect(writes_for.call).to eq 1
    4.times { |index| Post.create!(title: "Second #{index}") }
    expect(writes_for.call).to eq 2
  end

  it "creates a missing vector in the default slot and keeps an existing one's id and updated_at" do
    missing = Post.create!(title: "No vector yet")
    present = Post.create!(title: "Has a vector")
    present.search_vector.reindex!("stale")
    vector = present.search_vector.reload
    travel 1.minute do
      expect(described_class.call).to eq 2
    end

    created = SearchVector.find_by!(entity_id: missing.id)
    expect(created.slot).to eq ""
    expect(created.created_at).to be_present
    expect(created.updated_at).to eq created.created_at
    expect(documents.fetch(missing.id)).to eq expected_document(["No vector yet"])
    kept = SearchVector.find_by!(entity_id: present.id)
    expect(kept.id).to eq vector.id
    expect(kept.updated_at).to eq vector.updated_at
    expect(documents.fetch(present.id)).to eq expected_document(["Has a vector"])
  end

  it "builds no SearchVector models, so their validations and callbacks do not run" do
    3.times { |index| Product.create!(title: "Product #{index}") }
    built = Hash.new(0)
    callback = ->(*args) { built[args.last[:class_name]] += args.last[:record_count] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { described_class.call }
    expect(built).not_to have_key("SearchVector")
    expect(SearchVector.count).to eq 3
  end
end
