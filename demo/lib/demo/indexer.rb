# frozen_string_literal: true

module Demo
  # The demo's second system, beside the geocoder the marketplace will add: an
  # entity-blind full-text indexer. It never names an entity class. It reads the
  # `texts` component table — every Text slot of every entity — and rebuilds
  # each entity's SearchVector from all of them. Posts get their title and body
  # indexed; a Group would get its name, description and rules; a User its bio.
  # Whether an entity *declares* SearchVector is the entity's business; the
  # indexer only writes where a virtual or persisted SearchVector already makes
  # sense, i.e. for entities that declare it.
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
      # reach reindex! together or the last fragment would replace the rest.
      ApplicationEntity.where(id: Text.select(:entity_id))
                       .find_in_batches(batch_size: batch_size)
                       .sum { |entities| reindex_batch(entities) }
    end

    def reindex_batch(entities)
      eligible = []
      entities.group_by(&:class).each do |type, owners|
        eligible.concat(owners) if type.components.include?(SearchVector)
      end
      return 0 if eligible.empty?

      entity_ids = eligible.map(&:id)
      # Only values are needed; avoid allocating Text models for every slot.
      values_by_entity = Text.where(entity_id: entity_ids).order(:slot)
                             .pluck(:entity_id, :value).group_by(&:first)
      vectors_by_entity = SearchVector.where(entity_id: entity_ids, slot: "").index_by(&:entity_id)

      eligible.each do |entity|
        vector = vectors_by_entity[entity.id] || SearchVector.new(entity: entity)
        values = values_by_entity.fetch(entity.id, []).map(&:last)
        vector.reindex!(*values)
      end
      eligible.size
    end
    private_class_method :reindex_batch
  end
end
