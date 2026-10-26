# frozen_string_literal: true

# ECS-41 experiment, kept so the decision can be revisited with numbers: does
# loading each component type once, instead of each slot's has_one through
# Rails' preloader, make includes_components cheaper? The decision (deferred)
# and the reasoning are in docs/design/grouped-preloads.md. Nothing here is
# used by the demo; the prototype lives only in this script.
#
#   RAILS_ENV=test bin/rails runner script/grouped_preload_experiment.rb
#
# Both measurements run inside a transaction that is rolled back, on the test
# database. The first loads the stress fixture's extra Product slots (six Text,
# six Counter) into this process only.
abort "Use RAILS_ENV=test" unless Rails.env.test?
require_relative "performance/models"

# The prototype: one query per component type for the owners' declared slots,
# each row written into its slot's has_one by hand.
def grouped_preload(owners, *component_classes)
  ids = owners.map(&:id)
  component_classes.each do |klass|
    declarations = owners.first.class.component_declarations.select { |d| d.component_class == klass }
    rows = klass.where(entity_id: ids, slot: declarations.map { |d| d.slot.to_s }).group_by { |r| [r.entity_id, r.slot] }
    owners.each do |owner|
      declarations.each do |d|
        row = rows[[owner.id, d.slot.to_s]]&.first
        owner.association(d.reader_name).target = row # the :nodoc: internal
        row.entity = owner if row # public writer: the row knows its owner
      end
    end
  end
  owners
end
# Median and p95 of n warm runs, with reads and allocations.
def measure(label, n = 200)
  reads = 0; sub = ->(*a) { p = a.last; reads += 1 if p[:sql].start_with?("SELECT") && !p[:cached] }
  ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(sub, "sql.active_record") { yield } }
  times = []; allocs = []
  ActiveRecord::Base.uncached do
    n.times do
      GC.start; a = GC.stat(:total_allocated_objects); t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000; allocs << GC.stat(:total_allocated_objects) - a
    end
  end
  times.sort!; allocs.sort!
  puts format("%-34s reads %3d  p50 %6.2f ms  p95 %6.2f ms  alloc %7d", label, reads, times[n / 2], times[(n * 0.95).ceil - 1], allocs[n / 2])
end

puts "== Stress fixture: 24 products with six Text and six Counter slots"
ActiveRecord::Base.transaction do
  Demo::Reset.call
  slots_t = Product.component_declarations.select { |d| d.component_class == Text }.map(&:reader_name)
  slots_c = Product.component_declarations.select { |d| d.component_class == Counter }.map(&:reader_name)
  puts "Product Text slots #{slots_t.size}, Counter slots #{slots_c.size}"
  24.times do |i|
    p = Product.create!(listing_state_status: "listed")
    (slots_t + slots_c).each { |r| r.to_s.end_with?("_text") ? p.public_send(r).value = "v#{i} #{r}" : p.public_send(r).count = i + 1 }
    p.save!
  end
  scope = -> { Product.order(:id).limit(24) }
  project = ->(products) { products.map { |p| [p.id, p.title, p.stock] + slots_t.map { |r| p.public_send(r).value } + slots_c.map { |r| p.public_send(r).count } } }
  expected = project.(scope.().includes_components(Text, Counter).to_a)
  raise "prototype differs" unless project.(grouped_preload(scope.().to_a, Text, Counter)) == expected
  measure("includes_components(Text, Counter)") { project.(scope.().includes_components(Text, Counter).to_a) }
  measure("grouped prototype") { project.(grouped_preload(scope.().to_a, Text, Counter)) }
  measure("named: title_text, stock_counter") { scope.().preload(:title_text, :stock_counter).map { |p| [p.id, p.title, p.stock] } }
  raise ActiveRecord::Rollback
end

puts "== The demo's remaining type-wide list preloads, on its seed data"
ActiveRecord::Base.transaction do
  Kernel.srand(38); Demo::Reset.call
  pages = {
    "posts index (Text x2, Counter)" => [-> { Post.published.order(:created_at).limit(24) }, [Text, Counter], ->(r) { r.map { |p| [p.title, p.body, p.likes] } }],
    "people (Name, Email, Image, Marker x2)" => [-> { User.order(:created_at).limit(24) }, [Name, Email, Image, Marker], ->(r) { r.map { |u| [u.name.to_s, u.email_address, u.avatar_image_url, u.moderator?, u.administrator?] } }],
    "sellers (Text x2, Image, Address)" => [-> { Company.order(:created_at).limit(24) }, [Text, Image, Address], ->(r) { r.map { |c| [c.name, c.description, c.logo_image_url, c.address.locality] } }],
  }
  pages.each do |label, (scope, types, project)|
    expected = project.(scope.().includes_components(*types).to_a)
    raise "#{label} differs" unless project.(grouped_preload(scope.().to_a, *types)) == expected
    measure("#{label}: current") { project.(scope.().includes_components(*types).to_a) }
    measure("#{label}: grouped") { project.(grouped_preload(scope.().to_a, *types)) }
  end
  raise ActiveRecord::Rollback
end
