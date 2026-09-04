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
    # @return [Integer] how many entities were reindexed
    def call
      by_entity = Text.order(:slot).group_by(&:entity_id)
      by_entity.sum do |entity_id, texts|
        entity = ApplicationEntity.find(entity_id)               # ADR-0008: the concrete subclass
        next 0 unless entity.class.components.include?(SearchVector)

        entity.search_vector.reindex!(*texts.map(&:value))
        1
      end
    end
  end
end
