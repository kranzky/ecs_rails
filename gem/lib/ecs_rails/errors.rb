# frozen_string_literal: true

module EcsRails
  # Base class for every error the gem raises.
  class Error < StandardError; end

  # Raised when `component` is given something that is not a EcsRails::Component.
  # See RFC-0004.
  class InvalidComponent < Error; end

  # Raised when `relates_to` is given a target that is not a concrete
  # EcsRails::Entity. See RFC-0012 / ADR-0013.
  #
  # A subclass of InvalidComponent on purpose. RFC-0012 left the choice open —
  # reuse InvalidComponent, or add a dedicated class — and this gets both: the
  # message is relationship-shaped ("relates_to :author expected ... an entity"),
  # while any existing `rescue InvalidComponent` and the RFC's own contract test
  # (`raise_error(EcsRails::InvalidComponent)`) still match, because a
  # relationship *is* a component under the hood. See EcsRails::Relationships.
  class InvalidRelationship < InvalidComponent; end

  # Raised when an entity declares the same component twice. See RFC-0002.
  class DuplicateComponent < Error; end

  # Raised at declaration time when two components on one entity would delegate
  # the same method name. See ADR-0004 and RFC-0005.
  class DelegationConflict < Error; end
end
