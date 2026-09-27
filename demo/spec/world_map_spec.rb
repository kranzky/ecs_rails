# frozen_string_literal: true

require "rails_helper"

# ECS-44: the geocoder page's server-drawn map. The projection must match the
# one that produced the committed coastline, or markers drift off their cities;
# marker grouping and label placement must be deterministic and must not let
# one label hide another label or dot, or the map stops being readable.
RSpec.describe Demo::WorldMap do
  def pin(lat, lng, place = "Somewhere", owner_type = "users")
    described_class::Pin.new(lat: lat, lng: lng, place: place, owner_type: owner_type)
  end

  def label_box(marker, (x, _y, anchor))
    width = marker.label.length * described_class::LABEL_CHAR_WIDTH
    left = anchor == "start" ? x : x - width
    [left, marker.y - described_class::LABEL_HEIGHT / 2, left + width, marker.y + described_class::LABEL_HEIGHT / 2]
  end

  def overlapping?(a, b)
    a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]
  end

  describe ".project" do
    it "maps longitude and latitude to one SVG unit per degree" do
      expect(described_class.project(0, 0)).to eq [180.0, 90.0]
      expect(described_class.project(-31.95, 115.86)).to eq [295.86, 121.95]
      expect(described_class.project(90, -180)).to eq [0.0, 0.0]
    end

    it "crops the view to the latitudes it names" do
      expect(described_class::VIEW_BOX).to eq "0 6 360 142"
    end
  end

  describe ".markers" do
    it "merges points in one town and keeps nearby towns apart" do
      london = pin(51.51, -0.12, "London", "companies")
      cambridge = pin(52.20, 0.13, "Cambridge", "companies")
      wilmslow = pin(53.33, -2.22, "Wilmslow")
      perth = [pin(-31.95, 115.86, "Perth"), pin(-31.94, 115.87, "Perth")]

      markers = described_class.markers([*perth, wilmslow, cambridge, london])

      expect(markers.map(&:places)).to eq [%w[Wilmslow], %w[Cambridge London], %w[Perth]]
      expect(markers.map(&:label)).to eq ["Wilmslow", "Cambridge & London · 2", "Perth · 2"]
      expect(markers.last.owner_types).to eq("users" => 2)
      expect(markers.last.x).to be_within(0.001).of(295.865)
    end

    it "gives the same markers whatever order the pins arrive in" do
      pins = [pin(40.71, -74.0, "New York"), pin(38.88, -77.09, "Arlington"), pin(40.72, -74.01, "New York")]

      expect(described_class.markers(pins.reverse)).to eq described_class.markers(pins)
    end

    it "names up to two places and counts the rest" do
      pins = [pin(1, 1, "A"), pin(1, 1.1, "B"), pin(1, 1.2, "C"), pin(1, 1.3, "C")]

      expect(described_class.markers(pins).first.label).to eq "C & A +1 · 4"
    end
  end

  describe ".label_positions" do
    it "places labels so none overlaps another label or dot, flipping or dropping as needed" do
      pins = [pin(51.51, -0.12, "London"), pin(53.33, -2.22, "Wilmslow"), pin(55.95, -3.19, "Edinburgh"),
              pin(40.71, -74.0, "New York"), pin(38.88, -77.09, "Arlington"), pin(38.91, -77.04, "Washington")]
      markers = described_class.markers(pins)
      positions = described_class.label_positions(markers)
      boxes = positions.map { |marker, position| label_box(marker, position) }
      dots = markers.map { |m| [m, [m.x - m.radius, m.y - m.radius, m.x + m.radius, m.y + m.radius]] }

      aggregate_failures do
        # This crowd forces flips: Wilmslow and Arlington & Washington go left.
        expect(positions.values.map(&:last)).to include("start", "end")
        boxes.combination(2).each { |a, b| expect(overlapping?(a, b)).to be(false) }
        positions.each do |marker, position|
          box = label_box(marker, position)
          dots.each { |owner, dot| expect(overlapping?(box, dot)).to be(false) unless owner == marker }
        end
      end
    end

    it "puts a label on the left when the right would leave the map" do
      marker = described_class.markers([pin(0, 179, "Edge")]).first

      _x, _y, anchor = described_class.label_positions([marker]).fetch(marker)
      expect(anchor).to eq "end"
    end
  end

  it "ships a coastline path the SVG can draw" do
    expect(described_class::LAND).to start_with("M")
    expect(described_class::LAND).to match(/\A[Mlz0-9. \-]+\z/)
    expect(described_class::LAND.count("M")).to be > 100
  end
end
