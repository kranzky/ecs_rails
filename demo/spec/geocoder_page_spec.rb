# frozen_string_literal: true

require "rails_helper"

# ECS-8: the geocoder's page shows its work before and after a run, beside the
# unchanged migration directory. ECS-44 adds a map of the located addresses,
# filtered by the owning entity's type from the entity side. The seed leaves one address waiting and one
# the simulated gazetteer cannot place, so a visitor's first run does something
# and every state is visible. Losing either would leave the page with nothing
# to show.
RSpec.describe "geocoder page", type: :request do
  before(:all) { Demo::Reset.call }

  def states
    response.body.scan(/badge badge--\w+">([^<]+)</).flatten.tally
  end

  it "shows every address's state, owners of each type, and the one migration" do
    get geocoder_path

    expect(response).to have_http_status(:ok)
    aggregate_failures do
      expect(states).to include("Waiting for the geocoder" => 1, "Place not found" => 1)
      expect(response.body.scan(%r{<span class="badge ">Not paired</span>}).size).to eq Order.count * 2 + Invoice.count
      expect(response.body).to include("Company", "User", "Order", "Invoice")
      expect(response.body).to include("20260904080008_ecs_rails_install.rb")
      expect(response.body).to include("Simulated coordinates")
    end
  end

  it "runs the geocoder, redoing only the waiting address" do
    post geocoder_path

    expect(response).to redirect_to(geocoder_path)
    expect(flash[:notice]).to eq "The geocoder wrote 1 Geolocation."
    follow_redirect!
    expect(states).not_to include("Waiting for the geocoder")

    post geocoder_path
    expect(flash[:notice]).to start_with("Nothing to do")
  end

  it "shows simulated coordinates, or why there are none, on profile pages" do
    ada = User.with_component(Name, given: "Ada").first
    katherine = User.with_component(Name, given: "Katherine").first

    get user_path(ada)
    expect(response.body.scan("(simulated)").size).to eq 2
    get user_path(katherine)
    expect(response.body).to include("The simulated gazetteer does not know this place")
    get company_path(Company.first)
    expect(response.body).to include("(simulated)")
  end

  describe "the map (ECS-44)" do
    def places
      response.body.scan(%r{<li><strong>([^<]+)</strong> <span class="count">([^<]+)</span>}).to_h
    end

    # The seed leaves Alan's Wilmslow address waiting, so six are located.
    it "plots every located address, merging towns that share a dot" do
      get geocoder_path

      expect(response.body).to include('<svg class="world-map"', "Map · 6 located addresses")
      expect(places).to eq(
        "Cambridge and London" => "2 companies", "New York" => "1 company",
        "Arlington" => "1 user", "Perth" => "2 users"
      )
      expect(response.body).to include("Cambridge &amp; London · 2")
    end

    it "filters the map and the address table by the owning entity's type" do
      get geocoder_path(model: "companies")

      expect(response.body).to include("Geolocation.where(entity: Company.all)", "Map · 3 located addresses")
      expect(places.keys).to eq ["Cambridge and London", "New York"]
      expect(response.body).to include("Addresses · 3")
      expect(response.body).not_to include('<span class="badge">User</span>')
      expect(response.body).to match(%r{<a class="btn btn--sm btn--primary" aria-current="page" href="/geocoder\?model=companies">})
    end

    it "shows everything for a type that owns no located address, or a bad value" do
      %w[orders nope].each do |model|
        get geocoder_path(model: model)

        expect(response.body).to include("Map · 6 located addresses", "Addresses · 11")
        expect(response.body).not_to include("Geolocation.where(entity:")
      end
    end

    it "keeps the filter when paging through the address table" do
      allow(Kaminari.config).to receive(:default_per_page).and_return(2)

      get geocoder_path(model: "users")

      expect(response.body).to include("/geocoder?model=users&amp;page=2")
    end
  end
end
