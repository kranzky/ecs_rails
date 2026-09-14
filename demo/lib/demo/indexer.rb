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
      # reach reindex! together or the last fragment would replace the rest.
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

      entity_ids = eligible_entities.map(&:id)
      # Only values are needed; avoid allocating Text models for every slot.
      values_by_entity = Text.where(entity_id: entity_ids).order(:slot)
                             .pluck(:entity_id, :value).group_by(&:first)
      vectors_by_entity = SearchVector.where(entity_id: entity_ids, slot: "").index_by(&:entity_id)

      eligible_entities.each do |entity|
        vector = vectors_by_entity[entity.id] || SearchVector.new(entity: entity)
        values = values_by_entity.fetch(entity.id, []).map(&:last)
        vector.reindex!(*values)
      end
      eligible_entities.size
    end
    private_class_method :reindex_batch
  end
end
