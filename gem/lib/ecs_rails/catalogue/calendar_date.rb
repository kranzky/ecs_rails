# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A calendar date: a birthday, a due date. A date is not a timestamp — it has
    # no time zone. Named so as never to shadow Ruby's `Date`.
    module CalendarDate
      extend Definition

      table "calendar_dates"
      schema do |t|
        t.date :date, default: nil
      end

      # @return [Boolean] whether the date is set and before today
      def past?
        date.present? && date < ::Date.current
      end

      # @return [Boolean]
      def today?
        date == ::Date.current
      end
    end
  end
end
