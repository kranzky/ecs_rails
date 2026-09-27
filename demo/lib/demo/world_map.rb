# frozen_string_literal: true

module Demo
  # The geocoder page's map (ECS-44): Geolocations drawn on an inline SVG world
  # map. No JavaScript, tiles or network calls, in keeping with the simulated
  # geocoder. The coastline (land.path) is Natural Earth's public-domain 1:110m
  # land, converted once by script/build_world_map.rb.
  #
  # The projection is equirectangular, one SVG unit per degree: x is longitude
  # + 180, y is 90 - latitude. The conversion script uses the same formula, so
  # markers land on the coastline.
  module WorldMap
    LAND = File.read(File.expand_path("world_map/land.path", __dir__)).freeze

    # Visible latitudes. Antarctica and the high Arctic are cropped: no
    # gazetteer place is there, and they would take a third of the height.
    NORTH = 84
    SOUTH = -58
    VIEW_BOX = "0 #{90 - NORTH} 360 #{NORTH - SOUTH}"

    # At world scale a town is a dot: points closer than this many degrees
    # share one marker, which says how many points it holds.
    MERGE_DISTANCE = 1.5

    # Label metrics in SVG units (degrees), matching .world-map__label's size.
    LABEL_HEIGHT = 4.2
    LABEL_CHAR_WIDTH = 2.4

    # One geocoded address to draw. `owner_type` is the entity model name
    # ("users"); `place` is the address's locality.
    Pin = Data.define(:lat, :lng, :place, :owner_type)

    # Pins close enough to share a dot, at their mean position.
    Marker = Data.define(:x, :y, :pins) do
      # @return [Array<String>] the localities the pins name, most common first
      def places
        names = pins.map { |pin| pin.place.presence || "Unnamed place" }
        names.tally.sort_by { |name, count| [-count, name] }.map(&:first)
      end

      # @return [Float] the dot grows a little with the points it holds
      def radius
        [1.6 + 0.5 * (pins.size - 1), 4].min
      end

      # @return [String] the label drawn beside the dot: up to two place
      # names, how many more, and the point count when there is more than one
      def label
        text = places.first(2).join(" & ")
        text += " +#{places.size - 2}" if places.size > 2
        pins.size > 1 ? "#{text} · #{pins.size}" : text
      end

      # @return [Hash{String => Integer}] pins per entity model, e.g. {"users" => 2}
      def owner_types
        pins.map(&:owner_type).tally.sort.to_h
      end
    end

    module_function

    # @return [Array(Float, Float)] the SVG point for a coordinate
    def project(lat, lng)
      [lng.to_f + 180, 90 - lat.to_f]
    end

    # Groups pins into markers. Each pin joins the first marker whose first
    # pin is within MERGE_DISTANCE, else starts its own. Pins are sorted
    # first, so the same pins always give the same markers.
    #
    # @param pins [Array<Pin>]
    # @return [Array<Marker>] ordered north to south, then west to east
    def markers(pins)
      groups = []
      pins.sort_by { |pin| [-pin.lat.to_f, pin.lng.to_f] }.each do |pin|
        group = groups.find { |members| close?(members.first, pin) }
        group ? group << pin : groups << [pin]
      end
      groups.map do |members|
        points = members.map { |pin| project(pin.lat, pin.lng) }
        Marker.new(x: points.sum(&:first) / points.size, y: points.sum(&:last) / points.size, pins: members)
      end
    end

    # Where each marker's label goes, so labels neither overlap each other nor
    # hide another dot: to the right of the dot, else to the left, else
    # nowhere (the dot's tooltip and the list after the map still name it).
    # Busier markers choose first. Text width is estimated, not measured: the
    # map is drawn on the server, where there are no font metrics.
    #
    # @param markers [Array<Marker>]
    # @return [Hash{Marker => Array(Float, Float, String)}] x, y and
    #   text-anchor for each marker that gets a label
    def label_positions(markers)
      taken = markers.map { |marker| dot_box(marker) }
      busiest_first = markers.sort_by { |marker| [-marker.pins.size, marker.y, marker.x] }
      busiest_first.each_with_object({}) do |marker, positions|
        placement = label_placements(marker).find { |candidate| fits?(candidate[:box], taken) }
        next if placement.nil?

        taken << placement[:box]
        positions[marker] = [placement[:x], marker.y + LABEL_HEIGHT / 3, placement[:anchor]]
      end
    end

    # Boxes are [left, top, right, bottom] in SVG units.
    def label_placements(marker)
      width = marker.label.length * LABEL_CHAR_WIDTH
      top = marker.y - LABEL_HEIGHT / 2
      right_of_dot = marker.x + marker.radius + 1
      left_of_dot = marker.x - marker.radius - 1
      [{ x: right_of_dot, anchor: "start", box: [right_of_dot, top, right_of_dot + width, top + LABEL_HEIGHT] },
       { x: left_of_dot, anchor: "end", box: [left_of_dot - width, top, left_of_dot, top + LABEL_HEIGHT] }]
    end
    private_class_method :label_placements

    def dot_box(marker)
      [marker.x - marker.radius, marker.y - marker.radius, marker.x + marker.radius, marker.y + marker.radius]
    end
    private_class_method :dot_box

    def fits?(box, taken)
      box[0] >= 0 && box[2] <= 360 && taken.none? { |other| overlap?(box, other) }
    end
    private_class_method :fits?

    def overlap?(a, b)
      a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
    end
    private_class_method :overlap?

    def close?(a, b)
      Math.hypot(a.lat.to_f - b.lat.to_f, a.lng.to_f - b.lng.to_f) <= MERGE_DISTANCE
    end
    private_class_method :close?
  end
end
