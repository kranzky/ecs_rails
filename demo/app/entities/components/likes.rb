# frozen_string_literal: true

# Shared by Post and Comment. Behaviour lives with the data (ADR-0001).
class Likes < ApplicationComponent
  def increment!
    update!(count: (count || 0) + 1)
  end
end
