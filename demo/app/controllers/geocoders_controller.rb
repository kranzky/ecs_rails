# frozen_string_literal: true

# The geocoder's page: a map of the located addresses, every address with its
# pair's state, and a button that runs Demo::Geocoder. The system is the point;
# this controller only shows its work.
class GeocodersController < ApplicationController
  # The most points the map draws. The hourly demo reset keeps it far below.
  MAP_LIMIT = 1_000

  def show
    @model_counts = located_counts_by_model
    # Only a model that owns located points is accepted; anything else,
    # including a typo in the URL, shows everything.
    @model = params[:model].presence_in(@model_counts.keys)
    # The same resolution the gem uses to load a row's subclass (ADR-0008):
    # "users" is User. Safe because @model came from the entities table.
    @owner_class = @model&.classify&.constantize

    @located_total = @model ? @model_counts.fetch(@model) : @model_counts.values.sum
    @markers = Demo::WorldMap.markers(pins)
    @addresses = paginate_list(owned(Address).order(created_at: :asc, id: :asc)).preload(:entity)
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

  private

  def located
    Geolocation.where.not(lat: nil).where.not(lng: nil)
  end

  # A component table does not know entity types; the entities table does
  # (ADR-0002), so the count by type is a join to it.
  def located_counts_by_model
    located.joins(:entity).group("entities.model").count.sort.to_h
  end

  # Narrows a component query to the chosen entity type, from the entity side:
  # Geolocation.where(entity: User.all) is an IN over User's default scope.
  def owned(scope)
    @owner_class ? scope.where(entity: @owner_class.all) : scope
  end

  # The map's points, plucked rather than loaded: position, the owner's model
  # and the paired address's locality for the label.
  def pins
    rows = owned(located).joins(:entity).order(:id).limit(MAP_LIMIT)
                         .pluck(:entity_id, :slot, :lat, :lng, "entities.model")
    places = Address.where(entity_id: rows.map(&:first).uniq)
                    .pluck(:entity_id, :slot, :locality)
                    .to_h { |entity_id, slot, locality| [[entity_id, slot], locality] }
    rows.map do |entity_id, slot, lat, lng, model|
      Demo::WorldMap::Pin.new(lat: lat, lng: lng, place: places[[entity_id, slot]], owner_type: model)
    end
  end
end
