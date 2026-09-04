# frozen_string_literal: true

module EcsRails
  module Catalogue
    # PostgreSQL full-text search with no dependency: a `tsvector` and a GIN
    # index. Rebuilt from an entity's texts by an entity-blind Indexer system.
    #
    #   post.search_vector.reindex!(post.title_text, post.body_text)
    #   SearchVector.matching("composable").pluck(:entity_id)
    module SearchVector
      extend Definition

      table "search_vectors"
      schema do |t|
        t.tsvector :document, default: nil
        t.index :document, using: :gin
      end

      included do
        # Rows whose document matches `query` (plainto_tsquery, `simple` config).
        #
        # @param query [String]
        # @return [ActiveRecord::Relation]
        scope :matching, ->(query) { where("document @@ plainto_tsquery('simple', ?)", query) }
      end

      # Rebuilds the document from `texts` and saves.
      #
      # @param texts [Array<String, nil>]
      # @return [void]
      def reindex!(*texts)
        save! unless persisted?
        self.class.where(id: id).update_all(["document = to_tsvector('simple', ?)", texts.flatten.compact.join(" ")])
        reload
      end
    end
  end
end
