# frozen_string_literal: true

# Regenerates lib/demo/world_map/land.path, the coastline behind the geocoder
# page's map (ECS-44), from Natural Earth's 1:110m land boundaries (public
# domain) as redistributed in TopoJSON by the world-atlas package (ISC):
#
#   curl -sSLo /tmp/land-110m.json https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/land-110m.json
#   ruby script/build_world_map.rb /tmp/land-110m.json
#
# Run once; the output is committed and the app never fetches anything. The
# projection is equirectangular with one SVG unit per degree, the same one
# Demo::WorldMap.project uses for the markers, so the two must change together.

require "json"

source = ARGV.fetch(0) { abort "usage: ruby script/build_world_map.rb land-110m.json" }
topology = JSON.parse(File.read(source))
scale_x, scale_y = topology.dig("transform", "scale")
shift_x, shift_y = topology.dig("transform", "translate")

# TopoJSON stores each arc once, quantized and delta-encoded; rings refer to
# arcs by index, with ~index meaning the arc reversed.
arcs = topology.fetch("arcs").map do |deltas|
  x = y = 0
  deltas.map do |dx, dy|
    x += dx
    y += dy
    [x * scale_x + shift_x, y * scale_y + shift_y]
  end
end

ring_points = lambda do |indexes|
  indexes.each_with_index.flat_map do |index, position|
    points = index.negative? ? arcs[~index].reverse : arcs[index]
    position.zero? ? points : points.drop(1) # consecutive arcs share an end point
  end
end

# Makes a ring continuous across the date line: a step of more than 180
# degrees of longitude is really a short step the other way round the globe.
unwrap = lambda do |points|
  offset = 0
  points.each_cons(2).with_object([points.first.dup]) do |((lng0, _), (lng1, lat1)), out|
    offset -= 360 if lng1 - lng0 > 180
    offset += 360 if lng1 - lng0 < -180
    out << [lng1 + offset, lat1]
  end
end

# SVG path numbers in tenths of a degree (the map's resolution), written
# relative to the previous point so most are one or two characters.
number = lambda do |tenths|
  whole, tenth = tenths.abs.divmod(10)
  digits = tenth.zero? ? whole.to_s : "#{whole unless whole.zero?}.#{tenth}"
  tenths.negative? ? "-#{digits}" : digits
end

to_path = lambda do |points, shift|
  tenths = points.map { |lng, lat| [((lng + 180 + shift) * 10).round, ((90 - lat) * 10).round] }
  deltas = tenths.each_cons(2).flat_map { |(x0, y0), (x1, y1)| [x1 - x0, y1 - y0] }
  # A minus sign separates numbers on its own; otherwise a space is needed.
  relative = deltas.map { |delta| number.call(delta) }
                   .each_with_index.map { |text, i| i.zero? || text.start_with?("-") ? text : " #{text}" }.join
  "M#{number.call(tenths[0][0])} #{number.call(tenths[0][1])}l#{relative}z"
end

subpaths = topology.dig("objects", "land", "geometries").flat_map do |geometry|
  polygons = geometry["type"] == "Polygon" ? [geometry["arcs"]] : geometry["arcs"]
  polygons.flat_map do |rings|
    rings.flat_map do |ring|
      points = ring_points.call(ring)
      # Antarctica lies below the map's southern edge (see Demo::WorldMap).
      next [] if points.size < 3 || points.all? { |_, lat| lat < -55 }

      points = unwrap.call(points)
      lngs = points.map(&:first)
      # A ring pushed past either edge by unwrapping is drawn again from the
      # other edge; the SVG viewport clips whatever falls outside.
      shifts = [0]
      shifts << -360 if lngs.max > 180
      shifts << 360 if lngs.min < -180
      shifts.map { |shift| to_path.call(points, shift) }
    end
  end
end

output = File.expand_path("../lib/demo/world_map/land.path", __dir__)
File.write(output, subpaths.join)
puts "Wrote #{subpaths.size} rings, #{File.size(output)} bytes to #{output}"
