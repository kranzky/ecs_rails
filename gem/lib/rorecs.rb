# frozen_string_literal: true

require "active_record"
require "active_support"

require "rorecs/version"
require "rorecs/errors"
require "rorecs/registry"
require "rorecs/entity"
require "rorecs/component"

# RoRECS — an Entity-Component-System reimagining of ActiveRecord.
#
# See docs/architecture.md for the invariants this library guarantees.
module Rorecs
  class << self
    # The process-wide component registry. See RFC-0002.
    def registry
      @registry ||= Registry.new
    end
  end
end

require "rorecs/railtie" if defined?(Rails::Railtie)
