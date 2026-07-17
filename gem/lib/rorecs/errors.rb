# frozen_string_literal: true

module Rorecs
  # Base class for every error the gem raises.
  class Error < StandardError; end

  # Raised when `component` is given something that is not a Rorecs::Component.
  # See RFC-0004.
  class InvalidComponent < Error; end

  # Raised when an entity declares the same component twice. See RFC-0002.
  class DuplicateComponent < Error; end

  # Raised at declaration time when two components on one entity would delegate
  # the same method name. See ADR-0004 and RFC-0005.
  class DelegationConflict < Error; end
end
