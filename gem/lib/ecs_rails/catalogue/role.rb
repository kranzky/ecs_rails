# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A role name: `member`, `owner`, `admin`. Data that belongs to a link, so
    # it usually sits on a join entity (`Membership`, `Employment`).
    module Role
      extend Definition

      table "roles"
      schema do |t|
        t.string :name, default: nil
      end

      # @param value [String, Symbol]
      # @return [Boolean]
      def is?(value)
        name == value.to_s
      end
    end
  end
end
