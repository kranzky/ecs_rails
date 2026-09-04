# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A person's name (schema.org `givenName` / `familyName` / `name`).
    #
    # `given` and `family` for names that split; `full` for the ones that do
    # not — mononyms, or an order that is not given-then-family. An
    # organisation's name is `Text` under slot `name`, not this.
    #
    #   user.name.given = "Ada"; user.name.family = "Lovelace"
    #   user.name.to_s              # => "Ada Lovelace"
    #   user.name.initials          # => "AL"
    module Name
      extend Definition

      table "names"
      schema do |t|
        t.string :given,  default: nil
        t.string :family, default: nil
        t.string :full,   default: nil
      end

      # The display form: `full` when set, else given and family joined.
      #
      # @return [String]
      def to_s
        full.presence || [given, family].compact_blank.join(" ")
      end

      # @return [String] the first letters of given and family, e.g. "AL"
      def initials
        [given, family].compact_blank.map { |part| part[0] }.join.upcase
      end
    end
  end
end
