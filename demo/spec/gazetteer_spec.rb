# frozen_string_literal: true

require "rails_helper"

# ECS-8: the geocoder's stand-in for a real service. Its answers must be
# deterministic, or a rerun of an unchanged address would look like a change;
# and it must say "not found" rather than invent a point for an unknown place.
RSpec.describe Demo::Gazetteer do
  def address(**attributes)
    Address.new({ line1: "12 Hay St", locality: "Perth", region: "WA", postcode: "6000", country: "AU" }.merge(attributes))
  end

  it "places a known city near its centre, the same way every time" do
    point = described_class.lookup(address)

    expect(point).to eq described_class.lookup(address)
    expect(point[0]).to be_within(Demo::Gazetteer::NUDGE).of(-31.9523)
    expect(point[1]).to be_within(Demo::Gazetteer::NUDGE).of(115.8613)
  end

  it "gives two streets in one city two different points" do
    expect(described_class.lookup(address)).not_to eq described_class.lookup(address(line1: "1 Murray St"))
  end

  it "ignores the case and spacing of the locality and country" do
    expect(described_class.lookup(address(locality: "  perth ", country: "au"))).to eq described_class.lookup(address)
  end

  it "does not find an unknown place, a blank locality or a missing country" do
    expect(described_class.lookup(address(locality: "Hampton", country: "US"))).to be_nil
    expect(described_class.lookup(address(locality: nil))).to be_nil
    expect(described_class.lookup(address(country: nil))).to be_nil
    expect(described_class.lookup(Address.new)).to be_nil
  end

  it "keeps every known place's points on the globe" do
    Demo::Gazetteer::PLACES.each do |country, places|
      places.each_key do |locality|
        lat, lng = described_class.lookup(address(locality: locality, country: country))
        expect(lat).to be_between(-90, 90)
        expect(lng).to be_between(-180, 180)
      end
    end
  end
end
