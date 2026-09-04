# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0014: labelled (plural) components, decided by ADR-0015.
#
# One component type, declared more than once on an entity under distinct
# labels, each label a singleton with its own reader:
#
#   class User < ApplicationEntity
#     component Address                      # slot ""         → user.address
#     component Address, prefix: :business   # slot "business" → user.business_address
#   end
#
# The discriminator is the `slot` column, present on every component table with
# a unique index on (entity_id, slot). Everything singular — the lazy reader,
# presence, delegation, validation keys, querying, preloading — must work per
# slot with no new machinery, and singular components must be byte-identical to
# before (slot "").
#
# Address (spec/support/models.rb, table spec/support/schema.rb) is the
# fixture — the short name ADR-0016 frees up for the catalogue, and the one the
# RFC's examples (`business_address`) assume. It is declared here on throwaway
# entities so the shared User keeps its query counts for the preloading spec.
RSpec.describe "labelled components (slots)" do
  before { EcsRails.registry.clear! }

  # A user with a default and a business address. Declared per example, so a
  # failure in one cannot leave a half-built class for the next.
  def declare_user
    stub_const("Customer", Class.new(ApplicationEntity))
    Customer.component Address
    Customer.component Address, prefix: :business
    Customer
  end

  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- the RFC's own example tests -------------------------------------------
  describe "the RFC's contract" do
    it "reads and writes each slot independently" do
      u = declare_user.create!
      u.business_address.line1 = "1 St Georges Tce"
      u.address.line1   = "10 Marine Pde"
      u.save!

      expect(u.reload.business_address.line1).to eq "1 St Georges Tce"
      expect(u.address.line1).to eq "10 Marine Pde"
    end

    it "keeps each slot lazy until dirtied" do
      expect(declare_user.create!.business_address.persisted?).to be false
    end

    it "generates a per-slot presence predicate" do
      u = declare_user.create!
      u.add(Address, prefix: :business)

      expect(u.business_address?).to be true
      expect(u.address?).to be false
    end

    it "prefixes delegated methods" do
      u = declare_user.create!
      u.business_address_line1 = "1 St Georges Tce" # delegated

      expect(u.business_address.line1).to eq "1 St Georges Tce"
    end

    it "omits delegation when delegate: false" do
      stub_const("Supplier", Class.new(ApplicationEntity))
      Supplier.component Address, prefix: :remit, delegate: false

      expect(Supplier.new).to respond_to(:remit_address, :remit_address?)
      expect(Supplier.new).not_to respond_to(:remit_address_line1)
    end

    it "filters by slot through with_component" do
      klass = declare_user
      perth = klass.create!
      perth.business_address.region = "WA"
      perth.save!
      home = klass.create!
      home.address.region = "WA"
      home.save!

      expect(klass.with_component(Address, slot: "business", region: "WA")).to contain_exactly(perth)
    end

    it "treats the same slot twice as a duplicate" do
      k = stub_const("Dup", Class.new(ApplicationEntity))
      k.component Address, prefix: :business

      expect { k.component Address, prefix: :business }
        .to raise_error(EcsRails::DuplicateComponent, /Dup.*Address.*business/)
    end

    it "leaves singular components byte-identical (default slot)" do
      u = User.create!
      u.email.address = "a@b.com"
      u.save!

      expect(u.reload.email.address).to eq "a@b.com" # RFC-0006 unchanged
      expect(u.email.slot).to eq ""
    end
  end

  # --- the slot column -------------------------------------------------------
  describe "the slot column" do
    it "presets the slot on a virtual labelled component, so the first write lands in it" do
      u = declare_user.create!

      expect(u.business_address.slot).to eq "business"
      expect(u.address.slot).to eq ""
    end

    it "does not count the preset slot as dirt" do
      # A preset slot is identity, like entity_id. If it counted, every labelled
      # virtual would be written on the next save — the feature inverted.
      u = declare_user.create!
      u.business_address

      expect(u.business_address).not_to be_ecs_dirty
      expect { u.save! }.not_to change(Address, :count)
    end

    it "writes one row per slot, both in the same table" do
      u = declare_user.create!
      u.business_address.line1 = "b"
      u.address.line1 = "p"

      expect { u.save! }.to change(Address, :count).by(2)
      expect(Address.where(entity_id: u.id).pluck(:slot)).to contain_exactly("", "business")
    end

    it "is enforced unique per (entity, slot) by the database" do
      u = declare_user.create!
      u.add(Address, prefix: :business)

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Address.create!(entity: u, slot: "business")
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "does not delegate slot — it is identity, not state" do
      u = declare_user.new

      expect(u).not_to respond_to(:business_address_slot, :address_slot, :slot)
    end

    it "scopes the default slot's has_one too, so a labelled row never answers for it" do
      # THE reason every has_one is slot-scoped, not only labelled ones: with an
      # unscoped default has_one, an entity holding only a business row would
      # read it back as its postal address.
      u = declare_user.create!
      u.business_address.line1 = "only business"
      u.save!

      fresh = Customer.find(u.id)
      expect(fresh.address).not_to be_persisted
      expect(fresh.address.line1).to be_nil
      expect(fresh.business_address.line1).to eq "only business"
    end

    it "loads the right row per slot after a reload" do
      u = declare_user.create!
      u.business_address.line1 = "b"
      u.address.line1 = "p"
      u.save!

      u.reload
      expect(u.business_address.line1).to eq "b"
      expect(u.address.line1).to eq "p"
    end
  end

  # --- the reader and has_one ------------------------------------------------
  describe "the reader" do
    it "is the label prefixed onto the singular" do
      declare_user
      expect(Customer.new).to respond_to(:address, :business_address)
    end

    it "is backed by a slot-scoped has_one" do
      declare_user
      reflection = Customer.reflect_on_association(:business_address)

      expect(reflection.macro).to eq :has_one
      expect(reflection.klass).to eq Address
      expect(reflection.foreign_key).to eq "entity_id"
      expect(reflection.scope).not_to be_nil
    end

    it "keeps the default slot's has_one under the bare singular" do
      declare_user
      expect(Customer.reflect_on_association(:address).klass).to eq Address
    end

    it "is recorded on the declaration" do
      declare_user
      declarations = EcsRails.registry.components_for(Customer)

      expect(declarations.map(&:slot)).to eq ["", "business"]
      expect(declarations.map(&:reader_name)).to eq %i[address business_address]
      expect(declarations.map(&:prefix)).to eq [nil, :business]
    end

    it "is found by declaration_for" do
      declare_user

      expect(Customer.declaration_for(Address).reader_name).to eq :address
      expect(Customer.declaration_for(Address, prefix: :business).reader_name).to eq :business_address
      expect(Customer.declaration_for(Address, prefix: :holiday)).to be_nil
      expect(Customer.declaration_for(Email)).to be_nil
    end

    it "lists the component once in components, twice in component_declarations" do
      declare_user

      expect(Customer.components).to eq [Address]
      expect(Customer.component_declarations.size).to eq 2
    end
  end

  # --- the label -------------------------------------------------------------
  describe "the label" do
    it "accepts a String as well as a Symbol" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Address, prefix: "business"

      expect(Solo.new).to respond_to :business_address
      expect(EcsRails.registry.components_for(Solo).first.slot).to eq "business"
    end

    it "rejects a label that is not a method-name segment" do
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Address, prefix: :"business address" }
        .to raise_error(ArgumentError, /not a valid slot label/)
      expect { Solo.component Address, prefix: :Business }
        .to raise_error(ArgumentError, /not a valid slot label/)
      expect { Solo.component Address, prefix: :"1st" }
        .to raise_error(ArgumentError, /not a valid slot label/)
    end

    it "rejects the empty string, which would silently mean the default slot" do
      stub_const("Solo", Class.new(ApplicationEntity))

      expect { Solo.component Address, prefix: "" }
        .to raise_error(ArgumentError, /not a valid slot label/)
    end

    it "leaves the class unchanged when the label is rejected" do
      stub_const("Solo", Class.new(ApplicationEntity))
      begin
        Solo.component Address, prefix: :"bad label"
      rescue ArgumentError
        # expected
      end

      expect(Solo.new).not_to respond_to :address
      expect(EcsRails.registry.components_for(Solo)).to be_empty
    end

    it "treats a Boolean prefix as the default slot" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Address, prefix: false

      expect(EcsRails.registry.components_for(Solo).first.slot).to eq ""
      expect(Solo.new).to respond_to(:address, :line1)
    end
  end

  # --- delegation ------------------------------------------------------------
  describe "delegation" do
    it "prefixes each slot's methods with that slot's reader" do
      u = declare_user.new

      expect(u).to respond_to(:address_line1, :address_line1=, :address_one_line)
      expect(u).to respond_to(:business_address_line1, :business_address_line1=, :business_address_one_line)
    end

    it "routes each prefixed writer to its own slot" do
      u = declare_user.create!
      u.address_line1 = "p"
      u.business_address_line1 = "b"

      expect(u.address.line1).to eq "p"
      expect(u.business_address.line1).to eq "b"
    end

    it "does not conflict between slots of one component" do
      # Two slots share every attribute name; prefixing with the slot reader is
      # exactly what keeps them apart (ADR-0016 + RFC-0014).
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Address, prefix: :home

      expect { Solo.component Address, prefix: :work }.not_to raise_error
    end

    it "conflicts when a labelled slot sits beside a bare default slot only if names clash" do
      # Bare default slot delegates `line1`; the labelled one `work_address_line1`.
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Address, prefix: false

      expect { Solo.component Address, prefix: :work }.not_to raise_error
      expect(Solo.new).to respond_to(:line1, :work_address_line1)
    end

    it "generates exactly the labelled set" do
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Address, prefix: :business
      generated = Solo.generated_component_methods.instance_methods(false).sort

      expect(generated).to eq %i[
        business_address business_address? business_address_country business_address_line1
        business_address_line1= business_address_one_line business_address_postcode
        business_address_postcode= business_address_region business_address_region=
      ]
    end

    it "routes flat mass assignment per slot" do
      u = declare_user.create!(address_line1: "p", business_address_line1: "b")

      u.reload
      expect(u.address.line1).to eq "p"
      expect(u.business_address.line1).to eq "b"
    end

    describe "delegate: false" do
      it "generates the reader and predicate only" do
        stub_const("Supplier", Class.new(ApplicationEntity))
        Supplier.component Address, prefix: :remit, delegate: false
        generated = Supplier.generated_component_methods.instance_methods(false).sort

        expect(generated).to eq %i[remit_address remit_address?]
      end

      it "is recorded on the declaration" do
        stub_const("Supplier", Class.new(ApplicationEntity))
        Supplier.component Address, prefix: :remit, delegate: false

        expect(EcsRails.registry.components_for(Supplier).first.options).to eq(delegate: false)
      end

      it "works on the default slot too" do
        stub_const("Supplier", Class.new(ApplicationEntity))
        Supplier.component Email, delegate: false

        expect(Supplier.new).to respond_to(:email, :email?)
        expect(Supplier.new).not_to respond_to(:email_address)
      end

      it "rejects only:/except: alongside it" do
        stub_const("Supplier", Class.new(ApplicationEntity))

        expect { Supplier.component Email, delegate: false, only: [:address] }
          .to raise_error(ArgumentError, /delegate: false/)
      end

      it "rejects a non-Boolean" do
        stub_const("Supplier", Class.new(ApplicationEntity))

        expect { Supplier.component Email, delegate: :some }
          .to raise_error(ArgumentError, /delegate:/)
      end
    end
  end

  # --- the primary attribute ---------------------------------------------------
  #
  # Decided after the forum rebuild (RFC-0014 amendment): a component with one
  # load-bearing attribute declares it `primary`, and a labelled slot then also
  # answers the bare slot name — `post.title` is `title_text.value`.
  describe "a primary attribute" do
    def text_class
      stub_const("Blurb", Class.new(ApplicationComponent) do
        self.table_name = "texts"
        primary :value
      end)
    end

    it "delegates the bare slot name to the primary, alongside the prefixed form" do
      text_class
      klass = stub_const("Article", Class.new(ApplicationEntity))
      klass.component Blurb, prefix: :title
      article = klass.create!(title: "Hello")

      aggregate_failures do
        expect(article.title).to eq "Hello"
        expect(article.title_blurb_value).to eq "Hello"
        expect(article.title_blurb).to be_a Blurb
        article.title = "Changed"
        expect(article.title_blurb.value).to eq "Changed"
        expect(article.reload.title).to eq "Hello" # the write is not saved yet
      end
    end

    it "does not add a bare pair on the default slot — there is no name to lend" do
      text_class
      klass = stub_const("Article", Class.new(ApplicationEntity))
      klass.component Blurb

      expect(klass.new).to respond_to(:blurb_value)
      expect(klass.new).not_to respond_to(:value)
    end

    it "is dropped with delegate: false and by except:" do
      text_class
      klass = stub_const("Article", Class.new(ApplicationEntity))
      klass.component Blurb, prefix: :title, delegate: false
      klass.component Blurb, prefix: :body, except: [:value]

      expect(klass.new).not_to respond_to(:title, :title=, :body, :body=, :body_blurb_value)
    end

    it "collides like any delegated name" do
      text_class
      klass = stub_const("Article", Class.new(ApplicationEntity))
      klass.relates_to :author, User

      expect { klass.component Blurb, prefix: :author }.to raise_error(EcsRails::DelegationConflict, /#author/)
    end

    it "rejects a primary that is not a delegable attribute" do
      stub_const("Blurb", Class.new(ApplicationComponent) do
        self.table_name = "texts"
        primary :valu
      end)
      klass = stub_const("Article", Class.new(ApplicationEntity))

      expect { klass.component Blurb, prefix: :title }.to raise_error(ArgumentError, /primary :valu/)
    end

    it "is inherited by a subclass of the component" do
      text_class
      stub_const("Snippet", Class.new(Blurb))

      expect(Snippet.primary).to eq :value
    end

    it "is nil when undeclared" do
      expect(Email.primary).to be_nil
    end
  end

  # --- reader collisions -----------------------------------------------------
  describe "a slot reader colliding with an existing name" do
    it "raises when the new reader is already a sibling's reader" do
      # `component Address, prefix: :business` wants `business_address`, which is
      # exactly the default reader of a component called BusinessAddress.
      stub_const("BusinessAddress", Class.new(ApplicationComponent) { self.table_name = "avatars" })
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component BusinessAddress

      expect { Solo.component Address, prefix: :business }
        .to raise_error(EcsRails::DelegationConflict, /#business_address.*already answers/m)
    end

    it "raises when the new reader is already a sibling's delegated method" do
      # Name delegates `name_title`; a `Title` component in slot :name would want
      # reader `name_title`.
      stub_const("Title", Class.new(ApplicationComponent) { self.table_name = "avatars" })
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component Name

      expect { Solo.component Title, prefix: :name }
        .to raise_error(EcsRails::DelegationConflict, /#name_title.*already answers/m)
    end

    it "leaves the class unchanged when it raises" do
      stub_const("BusinessAddress", Class.new(ApplicationComponent) { self.table_name = "avatars" })
      stub_const("Solo", Class.new(ApplicationEntity))
      Solo.component BusinessAddress
      begin
        Solo.component Address, prefix: :business
      rescue EcsRails::DelegationConflict
        # expected
      end

      expect(Solo.new).not_to respond_to :address
      expect(EcsRails.registry.components_for(Solo).size).to eq 1
    end
  end

  # --- presence (RFC-0009) ---------------------------------------------------
  describe "presence" do
    it "adds into one slot without touching the other" do
      u = declare_user.create!
      u.add(Address, prefix: :business)

      expect(u.has?(Address, prefix: :business)).to be true
      expect(u.has?(Address)).to be false
      expect(Address.where(entity_id: u.id).pluck(:slot)).to eq ["business"]
    end

    it "adds into the default slot when no prefix is given" do
      u = declare_user.create!
      u.add(Address)

      expect(u.address?).to be true
      expect(u.business_address?).to be false
    end

    it "removes one slot and leaves the other" do
      u = declare_user.create!
      u.add(Address)
      u.add(Address, prefix: :business)

      u.remove(Address, prefix: :business)

      expect(u.business_address?).to be false
      expect(u.address?).to be true
      expect(u.business_address).not_to be_persisted
    end

    it "resets the right reader when a slot's row is destroyed directly" do
      u = declare_user.create!
      u.add(Address)
      u.add(Address, prefix: :business)

      u.business_address.destroy

      expect(u.business_address).not_to be_persisted
      expect(u.address).to be_persisted
    end

    it "answers has? from the database, slot-scoped" do
      u = declare_user.create!
      Address.create!(entity: u, slot: "business")

      fresh = Customer.find(u.id)
      expect(fresh.has?(Address, prefix: :business)).to be true
      expect(fresh.has?(Address)).to be false
    end

    it "rejects a slot the entity does not declare" do
      u = declare_user.create!

      expect { u.add(Address, prefix: :holiday) }
        .to raise_error(EcsRails::InvalidComponent, /holiday/)
      expect { u.has?(Address, prefix: :holiday) }
        .to raise_error(EcsRails::InvalidComponent, /holiday/)
    end

    it "still rejects a component the entity does not declare at all" do
      u = declare_user.create!

      expect { u.add(Email) }.to raise_error(EcsRails::InvalidComponent)
      expect { u.has?("Email") }.to raise_error(EcsRails::InvalidComponent)
    end
  end

  # --- validation (RFC-0007) -------------------------------------------------
  describe "validation" do
    it "namespaces errors by the slot reader" do
      u = declare_user.create!
      u.business_address.postcode = "not a postcode"

      expect(u).not_to be_valid
      expect(u.errors[:"business_address.postcode"]).to be_present
      expect(u.errors[:"address.postcode"]).to be_empty
    end

    it "reads the slot in the human message" do
      u = declare_user.create!
      u.business_address.postcode = "nope"
      u.valid?

      expect(u.errors.full_messages).to include "Business address postcode is invalid"
    end
  end

  # --- querying (RFC-0010) ---------------------------------------------------
  describe "querying" do
    it "matches any slot without a prefix" do
      klass = declare_user
      a = klass.create!
      a.address.line1 = "x"
      a.save!
      b = klass.create!
      b.business_address.line1 = "y"
      b.save!
      klass.create!

      expect(klass.with_component(Address)).to contain_exactly(a, b)
    end

    it "takes prefix: as sugar for slot:" do
      klass = declare_user
      a = klass.create!
      a.address.line1 = "x"
      a.save!
      b = klass.create!
      b.business_address.line1 = "y"
      b.save!

      expect(klass.with_component(Address, prefix: :business)).to contain_exactly(b)
      expect(klass.with_component(Address, prefix: :business, line1: "y")).to contain_exactly(b)
      expect(klass.with_component(Address, prefix: :business, line1: "x")).to be_empty
    end

    it "excludes by slot through without_component" do
      klass = declare_user
      a = klass.create!
      a.address.line1 = "x"
      a.save!
      b = klass.create!
      b.business_address.line1 = "y"
      b.save!

      expect(klass.without_component(Address, prefix: :business)).to contain_exactly(a)
      expect(klass.without_component(Address)).to be_empty
    end
  end

  # --- preloading (RFC-0011) -------------------------------------------------
  describe "preloading" do
    it "preloads every slot of a component, one query each" do
      klass = declare_user
      2.times do |i|
        u = klass.create!
        u.address.line1 = "p#{i}"
        u.business_address.line1 = "b#{i}"
        u.save!
      end

      sql = capture_sql do
        klass.all.includes_components(Address).each { |u| [u.address.line1, u.business_address.line1] }
      end

      expect(sql.grep(/FROM "addresses"/).size).to eq 2 # one per slot
      expect(sql.size).to eq 3                                 # + the entities
    end

    it "preloads all slots with no arguments" do
      klass = declare_user
      klass.create!.tap { |u| u.business_address.line1 = "b"; u.save! }

      sql = capture_sql do
        klass.all.includes_components.each { |u| [u.address.line1, u.business_address.line1] }
      end

      expect(sql.size).to eq 3
    end

    it "still hands out a virtual for a slot with no row" do
      klass = declare_user
      klass.create!

      loaded = klass.all.includes_components(Address).first
      expect(loaded.business_address).not_to be_persisted
      expect(loaded.business_address.slot).to eq "business"
    end
  end

  # --- slot options (RFC-0014, slot configuration) --------------------------
  describe "slot options" do
    it "reads the default when the declaration passes nothing" do
      u = declare_user.create!

      expect(u.business_address.country).to eq "AU"
      expect(u.business_address.slot_options).to eq(country: "AU")
    end

    it "reads the declared value for its slot" do
      stub_const("Exporter", Class.new(ApplicationEntity))
      Exporter.component Address
      Exporter.component Address, prefix: :warehouse, country: "NZ"
      e = Exporter.create!

      expect(e.address.country).to eq "AU"
      expect(e.warehouse_address.country).to eq "NZ"
      expect(e.warehouse_address_country).to eq "NZ" # delegated like any method
    end

    it "is recorded on the declaration" do
      stub_const("Exporter", Class.new(ApplicationEntity))
      Exporter.component Address, prefix: :warehouse, country: "NZ"

      expect(Exporter.declaration_for(Address, prefix: :warehouse).slot_options).to eq(country: "NZ")
      expect(Exporter.declaration_for(Address, prefix: :warehouse).options).to eq({})
    end

    it "differs per entity for the same component class" do
      # The reason options resolve through the entity: State on an Order and
      # State on a Post are the same class with different configuration.
      stub_const("Exporter", Class.new(ApplicationEntity))
      Exporter.component Address, country: "NZ"
      stub_const("Importer", Class.new(ApplicationEntity))
      Importer.component Address, country: "SG"

      expect(Exporter.create!.address.country).to eq "NZ"
      expect(Importer.create!.address.country).to eq "SG"
    end

    it "resolves through the persisted row's entity too" do
      stub_const("Exporter", Class.new(ApplicationEntity))
      Exporter.component Address, country: "NZ"
      e = Exporter.create!
      e.address.line1 = "x"
      e.save!

      expect(Address.find_by!(entity_id: e.id).country).to eq "NZ"
    end

    it "is visible to the component's own behaviour" do
      stub_const("Exporter", Class.new(ApplicationEntity))
      Exporter.component Address, country: "NZ"
      e = Exporter.create!
      e.address.line1 = "1 Queen St"

      expect(e.address.one_line).to eq "1 Queen St, NZ"
    end

    it "rejects an option the component does not declare" do
      stub_const("Exporter", Class.new(ApplicationEntity))

      expect { Exporter.component Address, prefix: :warehouse, contry: "NZ" }
        .to raise_error(ArgumentError, /contry.*Declared slot options: :country/m)
      expect(Exporter.new).not_to respond_to :warehouse_address
    end

    it "rejects any option on a component that declares none" do
      stub_const("Exporter", Class.new(ApplicationEntity))

      expect { Exporter.component Email, verified_by: "x" }
        .to raise_error(ArgumentError, /Email does not accept.*verified_by.*none/m)
    end

    it "refuses a slot_option that would shadow an attribute" do
      expect do
        stub_const("Clashy", Class.new(ApplicationComponent) { self.table_name = "addresses" })
        Clashy.slot_option :line1
      end.to raise_error(ArgumentError, /shadow/)
    end

    it "lists the declared names and defaults on the class" do
      expect(Address.slot_option_names).to eq [:country]
      expect(Address.slot_option_defaults).to eq(country: "AU")
    end
  end

  # --- inheritance & reload --------------------------------------------------
  describe "inheritance" do
    it "inherits a parent's slots" do
      declare_user
      stub_const("Vip", Class.new(Customer))

      v = Vip.create!
      v.business_address.line1 = "b"
      v.save!

      expect(v.reload.business_address.line1).to eq "b"
      expect(Vip.declaration_for(Address, prefix: :business)).not_to be_nil
    end

    it "lets a subclass add a slot the parent lacks, and rejects one it has" do
      declare_user
      stub_const("Vip", Class.new(Customer))

      expect { Vip.component Address, prefix: :holiday }.not_to raise_error
      expect { Vip.component Address, prefix: :business }
        .to raise_error(EcsRails::DuplicateComponent, /business.*inherited/m)
    end
  end

  describe "surviving a class reload" do
    it "re-declares both slots on the new class without raising" do
      declare_user
      EcsRails.registry.clear!
      reloaded = stub_const("Customer", Class.new(ApplicationEntity))

      expect do
        reloaded.component Address
        reloaded.component Address, prefix: :business
      end.not_to raise_error
      expect(reloaded.create!.business_address.slot).to eq "business"
    end
  end
end
