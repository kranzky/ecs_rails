# frozen_string_literal: true

require "rails_helper"

# ECS-8: the geocoder's page shows its work before and after a run, beside the
# unchanged migration directory. The seed leaves one address waiting and one
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
end
