# frozen_string_literal: true

module Demo
  # Gives every Address a Geolocation in the same slot, for every kind of
  # entity, without naming one. It reads the `addresses` table rather than
  # User or Company: a component table is blind to entity type, so one query
  # finds a seller's address and a customer's shipping and billing addresses
  # alike. A new entity type takes part by declaring the pair; this file does
  # not change.
  #
  #   class User < ApplicationEntity
  #     component Address,     prefix: :shipping   # the address ...
  #     component Geolocation, prefix: :shipping   # ... and its pair, same slot
  #   end
  #
  # An address is left alone when its owner declares no Geolocation in that
  # slot. Orders and invoices keep Address snapshots for the record and have no
  # pair, so they are never geocoded. Coordinates come from Demo::Gazetteer,
  # which is simulated.
  module Geocoder
    module_function

    # Geocodes every paired address that is new or has changed since its last
    # lookup. An unchanged address is skipped, so running again is harmless.
    #
    # @param batch_size [Integer] maximum addresses held in memory at once
    # @return [Integer] how many Geolocations were written
    def call(batch_size: 100)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, "batch_size must be a positive integer"
      end

      addresses_to_geocode.preload(:entity).find_in_batches(batch_size: batch_size).sum do |addresses|
        paired = addresses.select { |address| paired?(address) }
        paired.each { |address| geocode(address) }
        paired.size
      end
    end

    # Addresses that have no Geolocation in the same slot describing their
    # current version: those never looked up, and those edited since. It
    # includes unpaired addresses; #paired? drops them, because pairing is a
    # Ruby declaration that SQL cannot see.
    #
    # @return [ActiveRecord::Relation<Address>]
    def addresses_to_geocode
      current = Geolocation.where("geolocations.entity_id = addresses.entity_id")
                           .where("geolocations.slot = addresses.slot")
                           .where("geolocations.geocoded_at >= addresses.updated_at")
      Address.where.not(current.arel.exists)
    end

    # Whether the address's owner declares a Geolocation in the address's slot.
    #
    # @param address [Address]
    # @return [Boolean]
    def paired?(address)
      address.entity.class.declaration_for(Geolocation, prefix: address.slot).present?
    end

    # Whether a Geolocation describes the address as it is now. The Ruby twin
    # of the condition in #addresses_to_geocode; the two must agree. An
    # address with no stored row has no version, so nothing is current for it.
    #
    # @param address [Address]
    # @param geolocation [Geolocation, nil] the pair in the same slot, if any
    # @return [Boolean]
    def current?(address, geolocation)
      return false if address.updated_at.nil? || geolocation&.geocoded_at.nil?

      geolocation.geocoded_at >= address.updated_at
    end

    # Looks one address up and records the answer on its pair.
    def geocode(address)
      lat, lng = Gazetteer.lookup(address)
      record(address, lat, lng)
    end
    private_class_method :geocode

    # Finds or builds the (entity, slot) pair and records the answer on it.
    #
    # The stamp is the address's updated_at, not the clock: if someone edits
    # the address while this runs, the edit is newer than the stamp and the
    # next run redoes it. A place the gazetteer does not know is recorded as
    # nil, nil, so it is not retried until the address changes, and any old
    # coordinates are cleared rather than left describing a previous address.
    #
    # The unique (entity_id, slot) index on `geolocations` stops two
    # overlapping runs from both inserting a pair: the slower insert raises,
    # and that run retries once, now finding the other run's row and updating
    # it. Each run writes a deterministic answer stamped with the version it
    # describes, so whichever write lands last is either current or visibly
    # stale. The savepoint keeps a caller's own transaction usable after the
    # failed insert.
    def record(address, lat, lng, retried: false)
      geolocation = Geolocation.find_or_initialize_by(entity: address.entity, slot: address.slot)
      geolocation.locate(lat, lng, at: address.updated_at)
      Geolocation.transaction(requires_new: true) { geolocation.save! }
    rescue ActiveRecord::RecordNotUnique
      raise if retried

      record(address, lat, lng, retried: true)
    end
    private_class_method :record
  end
end
