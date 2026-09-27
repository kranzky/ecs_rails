# frozen_string_literal: true

# The geocoder's page: every address, its pair's state, and a button that runs
# Demo::Geocoder. The system is the point; this controller only shows its work.
class GeocodersController < ApplicationController
  def show
    @addresses = paginate_list(Address.order(created_at: :asc, id: :asc)).preload(:entity)
    # One query for the page's pairs, looked up by (entity, slot) in the view.
    @geolocations = Geolocation.where(entity_id: @addresses.map(&:entity_id))
                               .index_by { |geolocation| [geolocation.entity_id, geolocation.slot] }
    @migrations = Rails.root.join("db/migrate").children.map { |path| path.basename.to_s }.sort
  end

  def create
    written = Demo::Geocoder.call
    notice = if written.zero?
               "Nothing to do: every paired address is already current."
             else
               "The geocoder wrote #{helpers.pluralize(written, 'Geolocation')}."
             end
    redirect_to geocoder_path, notice: notice
  end
end
