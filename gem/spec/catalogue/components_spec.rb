# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0017's shelf: each catalogue component's shape, validations and
# behaviour, declared on throwaway entities the way an application would. The
# mechanism (registry, schema declarations, install) is spec/catalogue_spec.rb.
#
# Email, Name and Address are the suite's `Catalogue*`-prefixed classes (their
# bare names are core fixtures); every other component is its plain class.
RSpec.describe "the catalogue components" do
  before { EcsRails.registry.clear! }

  def entity(name = "Thing", &block)
    stub_const(name, Class.new(ApplicationEntity)).tap { |k| k.class_eval(&block) }
  end

  describe "Name" do
    it "joins given and family, or uses full" do
      klass = entity { component CatalogueName }
      thing = klass.create!(catalogue_name_given: "Ada", catalogue_name_family: "Lovelace")

      expect(thing.catalogue_name.to_s).to eq "Ada Lovelace"
      expect(thing.catalogue_name.initials).to eq "AL"
      thing.catalogue_name.full = "Ada King, Countess of Lovelace"
      expect(thing.catalogue_name.to_s).to eq "Ada King, Countess of Lovelace"
    end
  end

  describe "Email" do
    it "validates the format and verifies" do
      klass = entity { component CatalogueEmail }
      thing = klass.create!
      thing.catalogue_email.address = "not an email"
      expect(thing).not_to be_valid

      thing.catalogue_email.address = "ada@example.com"
      thing.save!
      thing.catalogue_email.verify!
      expect(thing.reload.catalogue_email.verified).to be true
      expect(thing.catalogue_email.domain).to eq "example.com"
    end
  end

  describe "Password" do
    it "stores a digest and authenticates" do
      klass = entity { component Password }
      thing = klass.create!
      thing.password.password = "s3cret-s3cret"
      thing.save!

      row = Password.find_by!(entity_id: thing.id)
      aggregate_failures do
        expect(row.password_digest).not_to include "s3cret"
        expect(row.authenticate("s3cret-s3cret")).to be_truthy
        expect(row.authenticate("wrong")).to be false
      end
    end
  end

  describe "Phone" do
    it "accepts E.164 and rejects anything else" do
      klass = entity { component Phone, prefix: :mobile }
      thing = klass.create!
      thing.mobile_phone.e164 = "0412 345 678"
      expect(thing).not_to be_valid

      thing.mobile_phone.e164 = "+61412345678"
      thing.mobile_phone.extension = "204"
      expect(thing).to be_valid
      expect(thing.mobile_phone.to_s).to eq "+61412345678 x204"
    end
  end

  describe "Address" do
    it "renders one line and lines, and validates the country code" do
      klass = entity { component CatalogueAddress, prefix: :billing }
      thing = klass.create!
      thing.billing_catalogue_address.assign_attributes(line1: "1 St Georges Tce", locality: "Perth", region: "WA",
                                                         postcode: "6000", country: "AU")

      aggregate_failures do
        expect(thing.billing_catalogue_address.one_line).to eq "1 St Georges Tce, Perth, WA, 6000, AU"
        expect(thing.billing_catalogue_address.lines).to eq ["1 St Georges Tce", "Perth WA 6000", "AU"]
        thing.billing_catalogue_address.country = "Australia"
        expect(thing).not_to be_valid
      end
    end
  end

  describe "Geolocation" do
    it "locates, pairs with an address by slot, and bounds the coordinate" do
      klass = entity do
        component CatalogueAddress, prefix: :registered
        component Geolocation, prefix: :registered
      end
      thing = klass.create!
      thing.registered_geolocation.locate(-31.95, 115.86)
      thing.save!

      aggregate_failures do
        expect(thing.reload.registered_geolocation).to be_geocoded
        expect(thing.registered_geolocation.coordinates.map(&:to_f)).to eq [-31.95, 115.86]
        expect(thing.registered_geolocation.geocoded_at).to be_present
        thing.registered_geolocation.lat = 91
        expect(thing).not_to be_valid
      end
    end
  end

  describe "Link" do
    it "validates an http(s) URL and reads the host" do
      klass = entity { component Link, prefix: :website }
      thing = klass.create!
      thing.website_link.url = "ftp://x"
      expect(thing).not_to be_valid
      thing.website_link.url = "https://ecs-rails.kranzky.com/about"
      expect(thing).to be_valid
      expect(thing.website_link.host).to eq "ecs-rails.kranzky.com"
    end
  end

  describe "Text" do
    it "is the generic text under a slot" do
      klass = entity do
        component Text, prefix: :title
        component Text, prefix: :body
      end
      thing = klass.create!(title: "Hello", body: "one two three")

      aggregate_failures do
        expect(thing.reload.title).to eq "Hello"         # the primary, bare (RFC-0014 amendment)
        expect(thing.title_text.to_s).to eq "Hello"      # the component
        expect(thing.title_text_value).to eq "Hello"     # the prefixed form
        expect(thing.body_text.words).to eq 3
        expect(Text.where(entity_id: thing.id).pluck(:slot)).to contain_exactly("title", "body")
      end
    end
  end

  describe "Identifier" do
    it "is unique per slot at the database" do
      klass = entity { component Identifier, prefix: :sku }
      klass.create!(sku: "ABC-1")

      expect { klass.create!(sku: "ABC-1") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same value under another slot" do
      klass = entity do
        component Identifier, prefix: :sku
        component Identifier, prefix: :slug
      end

      expect { klass.create!(sku_identifier_value: "x", slug_identifier_value: "x") }.not_to raise_error
    end
  end

  describe "Counter" do
    it "increments atomically once persisted, and from virtual" do
      klass = entity { component Counter, prefix: :likes }
      thing = klass.create!

      aggregate_failures do
        expect(thing.likes).to eq 0 # the primary, bare
        expect(thing.likes_counter.increment!).to eq 1
        expect(thing.likes).to eq 1
        expect(thing.likes_counter).to be_persisted
        expect(thing.likes_counter.increment!(4)).to eq 5
        expect(thing.likes_counter.decrement!).to eq 4
        expect(Counter.find_by!(entity_id: thing.id, slot: "likes").count).to eq 4
      end
    end
  end

  describe "Rating" do
    it "keeps stars between one and five" do
      klass = entity { component Rating }
      thing = klass.create!
      thing.rating.stars = 6
      expect(thing).not_to be_valid
      thing.rating.stars = 5
      expect(thing).to be_valid
      expect(thing.rating).to be_rated
    end
  end

  describe "Timestamp" do
    it "stamps and knows past from future" do
      klass = entity { component Timestamp, prefix: :published }
      thing = klass.create!
      expect(thing.published_timestamp).not_to be_past

      thing.published_timestamp.stamp!
      expect(thing.reload.published_timestamp).to be_past
      thing.published_timestamp.at = 1.hour.from_now
      expect(thing.published_timestamp).to be_future
    end
  end

  describe "CalendarDate" do
    it "is a date, not a time" do
      klass = entity { component CalendarDate, prefix: :due }
      thing = klass.create!(due_calendar_date_date: Date.current)

      aggregate_failures do
        expect(thing.reload.due_calendar_date).to be_today
        expect(thing.due_calendar_date).not_to be_past
        expect(CalendarDate.columns_hash["date"].type).to eq :date
      end
    end
  end

  describe "Period" do
    it "knows current and overlapping, and rejects a backwards span" do
      klass = entity { component Period }
      thing = klass.create!
      period = thing.period
      period.starts_at = 1.hour.ago
      period.ends_at = 1.hour.from_now

      aggregate_failures do
        expect(period).to be_current
        expect(period.duration).to eq 2.hours
        expect(period.overlaps?(Time.current..2.hours.from_now)).to be true
        expect(period.overlaps?(3.hours.from_now..4.hours.from_now)).to be false
        period.ends_at = 2.hours.ago
        expect(thing).not_to be_valid
      end
    end
  end

  describe "Position" do
    it "orders within a slot" do
      klass = entity { component Position, prefix: :backlog }
      a = klass.create!(backlog_position_position: 2)
      b = klass.create!(backlog_position_position: 1)

      expect(Position.where(slot: "backlog").order(:position).pluck(:entity_id)).to eq [b.id, a.id]
    end
  end

  describe "State" do
    it "transitions within the slot's vocabulary and logs history" do
      klass = entity { component State, prefix: :order, states: %w[pending paid shipped] }
      thing = klass.create!
      state = thing.order_state

      aggregate_failures do
        expect(state.transition!("paid", event: "checkout")).to eq "paid"
        expect(state).to be_in(:paid)
        expect(state.transitions.size).to eq 1
        expect(state.transitions.first).to include("from" => nil, "to" => "paid", "event" => "checkout")
        expect { state.transition!("lost") }.to raise_error(ArgumentError, /"lost" is not one of/)
      end
    end

    it "is a plain enum with history: false" do
      klass = entity { component State, prefix: :visibility, states: %w[public private], history: false }
      thing = klass.create!
      thing.visibility_state.transition!("private")

      expect(thing.reload.visibility_state.transitions).to eq []
      expect(thing.visibility_state.status).to eq "private"
    end

    it "validates a directly assigned status against the vocabulary" do
      klass = entity { component State, prefix: :order, states: %w[pending paid] }
      thing = klass.create!
      thing.order_state.status = "lost"

      expect(thing).not_to be_valid
      expect(thing.errors[:"order_state.status"]).to include("must be one of pending, paid")
    end

    it "accepts anything when no vocabulary is declared" do
      klass = entity { component State }
      thing = klass.create!

      expect(thing.state.transition!("whatever")).to eq "whatever"
    end
  end

  describe "Tags" do
    it "adds, removes, restricts with allow: and finds by tag" do
      klass = entity { component Tags, prefix: :topics, allow: %w[ruby rails ecs] }
      thing = klass.create!
      thing.topics_tags.add("ruby", "ecs", "ruby")
      thing.save!

      aggregate_failures do
        expect(thing.reload.topics_tags.names).to eq %w[ruby ecs]
        expect(thing.topics_tags).to be_tagged("ecs")
        expect(Tags.tagged("ruby").pluck(:entity_id)).to eq [thing.id]
        thing.topics_tags.add("php")
        expect(thing).not_to be_valid
        thing.topics_tags.remove("php")
        expect(thing).to be_valid
      end
    end
  end

  describe "SearchVector" do
    it "indexes texts and matches a query" do
      klass = entity { component SearchVector }
      hit = klass.create!
      hit.search_vector.reindex!("Composable domain models", "Entities are identity")
      miss = klass.create!
      miss.search_vector.reindex!("Something else entirely")

      expect(SearchVector.matching("composable").pluck(:entity_id)).to eq [hit.id]
    end
  end

  describe "Discard" do
    it "soft-deletes as presence" do
      klass = entity { component Discard }
      thing = klass.create!
      thing.discard.discard!

      aggregate_failures do
        expect(thing.discard).to be_discarded
        expect(klass.with_component(Discard)).to contain_exactly(thing)
        thing.discard.undiscard!
        expect(klass.without_component(Discard)).to contain_exactly(thing)
        expect(thing.discard).not_to be_discarded
      end
    end
  end

  describe "Image" do
    it "holds a URL and alt text" do
      klass = entity { component Image, prefix: :avatar }
      thing = klass.create!(avatar_image_url: "https://example.com/a.png", avatar_image_alt: "Ada")

      expect(thing.reload.avatar_image).to be_present_url
      thing.avatar_image.url = "not a url"
      expect(thing).not_to be_valid
    end
  end

  describe "Role" do
    it "answers is?" do
      klass = entity { component Role }
      thing = klass.create!(role_name: "owner")

      expect(thing.reload.role.is?(:owner)).to be true
      expect(thing.role.is?("member")).to be false
    end
  end

  describe "Token" do
    it "stores a digest, verifies once until expiry, and is found by value" do
      klass = entity { component Token, prefix: :reset }
      thing = klass.create!
      raw = thing.reset_token.generate!(expires_in: 1.hour)

      aggregate_failures do
        expect(raw.length).to eq 32
        expect(Token.find_by!(entity_id: thing.id).digest).not_to eq raw
        expect(thing.reset_token.verify(raw)).to be true
        expect(thing.reset_token.verify("nope")).to be false
        expect(Token.find_by_token(raw)&.entity_id).to eq thing.id
        thing.reset_token.update!(expires_at: 1.minute.ago)
        expect(thing.reset_token).to be_expired
        expect(thing.reset_token.verify(raw)).to be false
        thing.reset_token.revoke!
        expect(Token.find_by_token(raw)).to be_nil
      end
    end
  end

  describe "Money" do
    it "adds, subtracts and scales in one currency, and formats" do
      klass = entity do
        component Money, prefix: :price
        component Money, prefix: :shipping
      end
      thing = klass.create!(price_money_amount_cents: 1999, shipping_money_amount_cents: 500)
      total = thing.price_money + thing.shipping_money

      aggregate_failures do
        expect(total.amount_cents).to eq 2499
        expect(total.to_s).to eq "USD 24.99"
        expect((thing.price_money - thing.shipping_money).amount_cents).to eq 1499
        expect((thing.price_money * 3).amount_cents).to eq 5997
        expect(thing.price_money.amount).to eq BigDecimal("19.99")
        thing.price_money.amount = 5
        expect(thing.price_money.amount_cents).to eq 500
      end
    end

    it "refuses to combine currencies" do
      klass = entity do
        component Money, prefix: :price
        component Money, prefix: :fee
      end
      thing = klass.create!(price_money_amount_cents: 100, fee_money_currency: "AUD")

      expect { thing.price_money + thing.fee_money }.to raise_error(EcsRails::Catalogue::Money::CurrencyMismatch, /USD.*AUD/)
    end

    it "validates the currency code" do
      klass = entity { component Money }
      thing = klass.create!
      thing.money.currency = "usd"

      expect(thing).not_to be_valid
    end

    it "is in the commerce set, not core" do
      expect(EcsRails::Catalogue::Money.set).to eq :commerce
    end
  end

  describe "primary attributes" do
    it "are declared on the single-attribute components, and only those" do
      primaries = EcsRails::Catalogue.components.to_h { |c| [c.catalogue_name, c.primary_attribute] }.compact

      expect(primaries).to eq(
        text: :value, identifier: :value, counter: :count, timestamp: :at, calendar_date: :date,
        rating: :stars, position: :position, role: :name
      )
    end

    it "reach the app class through the one-line include" do
      expect(Text.primary).to eq :value
      expect(Role.primary).to eq :name
      expect(State.primary).to be_nil
    end
  end

  describe "Relationship and Marker" do
    it "are catalogue components too, with their tables created from declarations" do
      expect(Relationship.table_name).to eq "relationships"
      expect(Marker.table_name).to eq "markers"
      expect(EcsRails::Catalogue::Marker.schema.columns).to be_empty
    end
  end
end
