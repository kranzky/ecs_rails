# frozen_string_literal: true

module Demo
  # A full-text system independent of concrete entity types. It reads all Text
  # slots for each owner and rebuilds a SearchVector only when that owner's
  # class declares one. New entity types participate through their declarations;
  # the system needs no list of product, post or other domain classes.
  module Indexer
    module_function

    # Reindexes every entity that has Texts and declares SearchVector.
    #
    # @param batch_size [Integer] maximum owners held at once
    # @return [Integer] how many entities were reindexed
    def call(batch_size: 100)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, "batch_size must be a positive integer"
      end

      # Batch owners, not component rows: all of an owner's Text slots must
      # reach one document together or the last fragment would replace the rest.
      ApplicationEntity.where(id: Text.select(:entity_id))
                       .find_in_batches(batch_size: batch_size)
                       .sum { |entities| reindex_batch(entities) }
    end

    def reindex_batch(entities)
      eligible_entities = []
      entities.group_by(&:class).each do |entity_class, owners|
        eligible_entities.concat(owners) if entity_class.components.include?(SearchVector)
      end
      return 0 if eligible_entities.empty?

      # Only values are needed; avoid allocating Text models for every slot.
      values_by_entity = Text.where(entity_id: eligible_entities.map(&:id)).order(:slot)
                             .pluck(:entity_id, :value).group_by(&:first)
      documents = eligible_entities.to_h do |entity|
        [entity.id, values_by_entity.fetch(entity.id, []).map(&:last).compact.join(" ")]
      end
      write(documents)
      documents.size
    end
    private_class_method :reindex_batch

    # One INSERT ... ON CONFLICT per batch writes every owner's document
    # (ECS-39). Each owner used to cost a reindex!: an UPDATE, a reload the
    # system never read, and a SELECT and an INSERT first when the vector was
    # missing. The text is the same SearchVector#reindex! builds (slot order,
    # nils dropped, `simple` dictionary), so the documents are identical.
    #
    # This is a system's bulk path, and it says what it skips. No SearchVector
    # model is built, so the class's validations and callbacks do not run: an
    # application that adds them to its SearchVector, and needs them here,
    # should call reindex! per owner instead. A new vector gets created_at and
    # updated_at; an existing one keeps its id (the unique (entity_id, slot)
    # index is the conflict target) and, as with reindex!, its updated_at.
    UPSERT = <<~SQL
      INSERT INTO %<table>s (entity_id, slot, document, created_at, updated_at)
      SELECT batch.entity_id, '', to_tsvector('simple', batch.text), :now, :now
      FROM unnest(ARRAY[:entity_ids]::uuid[], ARRAY[:texts]::text[]) AS batch(entity_id, text)
      ON CONFLICT (entity_id, slot) DO UPDATE SET document = EXCLUDED.document
    SQL

    def write(documents)
      sql = format(UPSERT, table: SearchVector.quoted_table_name)
      SearchVector.connection.exec_update(
        SearchVector.sanitize_sql_array([sql, { now: Time.current, entity_ids: documents.keys, texts: documents.values }]),
        "Demo::Indexer upsert"
      )
    end
    private_class_method :write
  end
end
