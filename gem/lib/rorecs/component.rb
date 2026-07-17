# frozen_string_literal: true

module Rorecs
  # An ordinary ActiveRecord model that belongs to exactly one entity.
  #
  # TODO: RFC-0003 — not yet implemented.
  class Component < ActiveRecord::Base
    self.abstract_class = true
  end
end
