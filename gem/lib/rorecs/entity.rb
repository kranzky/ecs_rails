# frozen_string_literal: true

module Rorecs
  # An immutable identity row. Carries no domain state.
  #
  # TODO: RFC-0001 — not yet implemented.
  class Entity < ActiveRecord::Base
    self.abstract_class = true
  end
end
