# frozen_string_literal: true

require "rails_helper"

# ECS-8: the demo's central System. One PORO pairs every Address with a
# Geolocation in the same slot by reading the component tables, deciding
# eligibility from declarations rather than a list of entity classes. If this
# changes, a new entity type would need geocoder edits to take part, reruns
# could rewrite or duplicate pairs, and stale coordinates could outlive an edit.
RSpec.describe Demo::Geocoder do
  before { ApplicationEntity.delete_all }

  def perth = { line1: "12 Hay St", locality: "Perth", region: "WA", postcode: "6000", country: "AU" }
  def sydney = { line1: "1 George St", locality: "Sydney", region: "NSW", postcode: "2000", country: "AU" }
  def london = { line1: "1 Marylebone Rd", locality: "London", postcode: "NW1 5LR", country: "GB" }
  def hampton = { line1: "1 NASA Dr", locality: "Hampton", region: "VA", postcode: "23666", country: "US" }

  def user_with(shipping: nil, billing: nil)
    user = User.new
    user.shipping_address.assign_attributes(shipping) if shipping
    user.billing_address.assign_attributes(billing) if billing
    user.save!
    user
  end

  def company_at(address)
    company = Company.new(name: "Seller")
    company.address.assign_attributes(address)
    company.save!
    company
  end

  def pair_for(entity, slot)
    Geolocation.find_by(entity_id: entity.id, slot: slot)
  end

  it "pairs addresses across entity types and slots, each result in its own slot" do
    company = company_at(london)
    user = user_with(shipping: perth, billing: sydney)
    order = Order.new
    order.shipping_address.assign_attributes(perth)
    order.save!

    expect(described_class.call).to eq 3

    aggregate_failures do
      expect(company.reload.geolocation.coordinates.map(&:to_f)).to eq Demo::Gazetteer.lookup(company.address)
      expect(user.reload.shipping_geolocation.coordinates.map(&:to_f)).to eq Demo::Gazetteer.lookup(user.shipping_address)
      expect(user.billing_geolocation.coordinates.map(&:to_f)).to eq Demo::Gazetteer.lookup(user.billing_address)
      expect(user.shipping_geolocation.lat).to be_within(0.02).of(-31.95)
      expect(user.billing_geolocation.lat).to be_within(0.02).of(-33.87)
      expect(Geolocation.pluck(:entity_id, :slot)).to contain_exactly(
        [company.id, ""], [user.id, "shipping"], [user.id, "billing"]
      )
      # The order's address is a snapshot with no Geolocation declared.
      expect(Geolocation.where(entity_id: order.id)).to be_empty
    end
  end

  it "is safe to repeat: an unchanged second run writes nothing" do
    user_with(shipping: perth, billing: sydney)
    company_at(london)
    described_class.call
    before = Geolocation.order(:id).pluck(:id, :lat, :lng, :geocoded_at, :updated_at)

    expect(described_class.call).to eq 0
    expect(Geolocation.order(:id).pluck(:id, :lat, :lng, :geocoded_at, :updated_at)).to eq before
  end

  it "recomputes only the address that changed, keeping its pair's identity" do
    user = user_with(shipping: perth, billing: perth.merge(line1: "PO Box 1815"))
    described_class.call
    shipping = pair_for(user, "shipping")
    billing = pair_for(user, "billing")

    user.billing_address.assign_attributes(sydney)
    user.save!

    expect(described_class.addresses_to_geocode.pluck(:slot)).to eq ["billing"]
    expect(described_class.call).to eq 1
    aggregate_failures do
      expect(pair_for(user, "billing").id).to eq billing.id
      expect(pair_for(user, "billing").lat).to be_within(0.02).of(-33.87)
      expect(pair_for(user, "billing").geocoded_at).to eq user.billing_address.reload.updated_at
      expect(pair_for(user, "shipping").attributes).to eq shipping.attributes
    end
  end

  it "records an unknown place without coordinates and does not retry it" do
    user = user_with(shipping: hampton)

    expect(described_class.call).to eq 1
    pair = pair_for(user, "shipping")
    aggregate_failures do
      expect(pair).to be_persisted
      expect(pair).not_to be_geocoded
      expect(pair.geocoded_at).to eq user.shipping_address.reload.updated_at
      expect(described_class.call).to eq 0
    end
  end

  it "clears coordinates when an address changes to one it cannot place, or is blanked" do
    user = user_with(shipping: perth, billing: sydney)
    described_class.call
    user.shipping_address.assign_attributes(hampton)
    # A cleared form keeps the Address row with every field nil.
    user.billing_address.assign_attributes(line1: nil, locality: nil, region: nil, postcode: nil, country: nil)
    user.save!

    expect(described_class.call).to eq 2
    expect(pair_for(user, "shipping")).not_to be_geocoded
    expect(pair_for(user, "billing")).not_to be_geocoded
    expect(Address.where(entity_id: user.id, slot: "billing").pick(:locality)).to be_nil
  end

  it "discovers an unfamiliar entity type from its declarations, slot by slot" do
    stub_const("Depot", Class.new(ApplicationEntity))
    Depot.class_eval do
      component Address,     prefix: :site
      component Geolocation, prefix: :site
      component Address,     prefix: :postal # no pair: left alone
    end
    depot = Depot.new
    depot.site_address.assign_attributes(london)
    depot.postal_address.assign_attributes(london.merge(line1: "PO Box 9"))
    depot.save!

    expect(described_class.call).to eq 1
    expect(Geolocation.where(entity_id: depot.id).pluck(:slot)).to eq ["site"]
  end

  it "redoes an address edited while its lookup was running" do
    user = user_with(shipping: perth)
    allow(Demo::Gazetteer).to receive(:lookup).and_wrap_original do |lookup, address|
      answer = lookup.call(address)
      # Someone saves a new address after this run read the old one.
      Address.find(address.id).update!(sydney)
      answer
    end

    expect(described_class.call).to eq 1
    expect(pair_for(user, "shipping").lat).to be_within(0.02).of(-31.95) # the old answer
    expect(described_class.addresses_to_geocode.pluck(:entity_id)).to eq [user.id]

    allow(Demo::Gazetteer).to receive(:lookup).and_call_original
    expect(described_class.call).to eq 1
    expect(pair_for(user, "shipping").lat).to be_within(0.02).of(-33.87)
  end

  it "retries onto the other run's row when an overlapping run inserted the pair first" do
    user = user_with(shipping: perth)
    competitor = nil
    allow(Geolocation).to receive(:find_or_initialize_by).and_wrap_original do |find, **attributes|
      pair = find.call(**attributes)
      # The other run inserts between this run's find and its save.
      competitor ||= Geolocation.create!(entity: user, slot: "shipping", lat: 0, lng: 0, geocoded_at: 1.day.ago)
      pair
    end

    # Inside a caller's transaction too: the savepoint keeps it usable.
    ApplicationEntity.transaction { expect(described_class.call).to eq 1 }

    pairs = Geolocation.where(entity_id: user.id, slot: "shipping")
    expect(pairs.pluck(:id)).to eq [competitor.id]
    expect(pairs.first.coordinates.map(&:to_f)).to eq Demo::Gazetteer.lookup(user.shipping_address)
    expect(described_class.addresses_to_geocode).to be_empty
  end

  it "reads addresses in bounded batches with the same result" do
    users = Array.new(5) { |index| user_with(shipping: perth.merge(line1: "#{index + 1} Hay St")) }

    expect(described_class.call(batch_size: 2)).to eq 5
    expect(Geolocation.where(entity_id: users.map(&:id)).count).to eq 5
    expect(Geolocation.distinct.count(:lat)).to eq 5
  end

  it "rejects invalid batch sizes before doing database work" do
    [0, -1, nil, "2", 1.5].each do |size|
      expect { described_class.call(batch_size: size) }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  describe ".current?" do
    it "agrees with the work list, and treats an unstored address as never current" do
      user = user_with(shipping: perth)
      expect(described_class.current?(user.shipping_address, nil)).to be false
      described_class.call
      expect(described_class.current?(user.shipping_address.reload, pair_for(user, "shipping"))).to be true
      expect(described_class.current?(User.new.shipping_address, Geolocation.new(geocoded_at: Time.current))).to be false
    end
  end
end

# Separate PostgreSQL connections: two runs really overlap on one pair. The
# first is held between finding no pair and inserting one, the second commits
# its insert, and the first's insert then meets the unique index. Queues decide
# the order; no sleeps.
RSpec.describe "overlapping geocoder runs" do
  self.use_transactional_tests = false

  before { @existing_ids = ApplicationEntity.pluck(:id) }
  after { ApplicationEntity.where.not(id: @existing_ids).delete_all }

  it "leaves one pair per address slot, and both runs finish" do
    user = User.new
    user.shipping_address.assign_attributes(locality: "Perth", country: "AU", line1: "12 Hay St")
    user.save!
    found = Queue.new
    release = Queue.new
    held = false
    allow(Geolocation).to receive(:find_or_initialize_by).and_wrap_original do |find, **attributes|
      pair = find.call(**attributes)
      if !held && attributes[:entity] == user
        held = true
        found << pair.new_record?
        Timeout.timeout(10) { release.pop }
      end
      pair
    end
    # Only this example's address: the test database may hold a seeded demo.
    scope = Address.where(entity_id: user.id)
    allow(Demo::Geocoder).to receive(:addresses_to_geocode).and_wrap_original { |original| original.call.merge(scope) }

    first = Thread.new { ApplicationEntity.connection_pool.with_connection { Demo::Geocoder.call } }
    expect(Timeout.timeout(10) { found.pop }).to be true
    second = Thread.new { ApplicationEntity.connection_pool.with_connection { Demo::Geocoder.call } }
    expect(Timeout.timeout(10) { second.value }).to eq 1
    release << true

    expect(Timeout.timeout(10) { first.value }).to eq 1
    expect(Geolocation.where(entity_id: user.id).pluck(:slot)).to eq ["shipping"]
    expect(user.reload.shipping_geolocation).to be_geocoded
  ensure
    release << true
    [first, second].compact.each { |thread| thread.join(10) || thread.kill }
  end
end
