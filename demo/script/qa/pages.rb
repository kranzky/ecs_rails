# frozen_string_literal: true

# Writes tmp/qa/pages.json: the pages and seeded records the ECS-35 rendered
# and accessibility review visits. Run after `bin/rails demo:reset`, because
# a reset gives every record a new ID:
#
#   bin/rails runner script/qa/pages.rb
#
# Then see script/qa/pages.js and script/qa/states.js.

def person(given) = User.with_component(Name, given: given).first!

ada = person("Ada")
alan = person("Alan")
wire = Product.with_component(Identifier, prefix: :sku, value: "NS-1").first!

pages = {
  "tour" => "/", "posts" => "/posts", "post" => "/posts/#{Post.published.first!.id}", "post-new" => "/posts/new",
  "people" => "/users", "person" => "/users/#{ada.id}", "person-new" => "/users/new",
  "groups" => "/groups", "group" => "/groups/#{Group.first!.id}",
  "market" => "/products", "product" => "/products/#{wire.id}",
  "sellers" => "/companies", "seller" => "/companies/#{wire.seller.id}",
  "basket" => "/users/#{alan.id}/basket", "checkout" => "/users/#{alan.id}/checkout/new",
  "orders" => "/users/#{ada.id}/orders", "order" => "/orders/#{Order.first!.id}",
  "invoice" => "/invoices/#{Invoice.first!.id}", "geocoder" => "/geocoder", "about" => "/about"
}

output = Rails.root.join("tmp/qa/pages.json")
output.dirname.mkpath
output.write(JSON.pretty_generate(
  pages: pages, product_edit: "/products/#{wire.id}/edit",
  ada: ada.id, alan: alan.id, grace: person("Grace").id, katherine: person("Katherine").id,
  engines: Company.with_component(Text, prefix: :name, value: "Analytical Engines Ltd").first!.id
))
puts "Wrote #{output}"
