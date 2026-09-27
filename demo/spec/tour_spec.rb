# frozen_string_literal: true

require "rails_helper"

# ECS-35: the tour at / is where a visitor starts: compose, use, inspect,
# extend, each step linking to a live page. Its code excerpts are typed into
# the view, so this spec checks every quoted line still exists in the demo's
# source; otherwise the tour would drift from the code it claims to show.
RSpec.describe "the tour", type: :request do
  before(:all) { Demo::Reset.call }

  def normalise(line)
    CGI.unescapeHTML(line).chomp.sub(/\s+#.*\z/, "").squeeze(" ").strip
  end

  it "is the root, with four steps that link to live pages for the acting user" do
    ada = User.with_component(Name, given: "Ada").first
    get root_path

    expect(response).to have_http_status(:ok)
    aggregate_failures do
      expect(response.body).to include("1 · Compose", "2 · Use", "3 · Inspect", "4 · Extend")
      expect(response.body).to include(%(href="/users/#{ada.id}">Open Ada Lovelace&#39;s profile))
      expect(response.body).to include(%(href="/products">Open the market), %(href="/geocoder">Run the geocoder))
      expect(response.body).to match(%r{href="/invoices/[0-9a-f-]+">Open invoice INV-\d+})
      expect(response.body).to include(%(aria-current="page" href="/">Start here))
    end
  end

  it "quotes only lines that exist in the demo's entities and systems" do
    get root_path
    source = Dir[Rails.root.join("app/entities/*.rb"), Rails.root.join("lib/demo/*.rb")]
             .flat_map { |path| File.readlines(path) }.map { |line| normalise(line) }.to_set
    quoted = response.body.scan(%r{<pre[^>]*class="code-block"[^>]*><code>(.*?)</code></pre>}m).flatten
                          .flat_map { |block| block.lines.map { |line| normalise(line) } }
                          .reject { |line| line.empty? || line.start_with?("#") || line == "end" }

    expect(quoted.size).to be > 15
    expect(quoted.reject { |line| source.include?(line) }).to be_empty
  end

  it "keeps the bulletin board at /posts" do
    get posts_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(aria-current="page" href="/posts">Posts))
  end
end
