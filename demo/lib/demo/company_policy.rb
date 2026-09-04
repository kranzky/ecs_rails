# frozen_string_literal: true

module Demo
  # Role-based authorization over the Employment join entity. A plain PORO —
  # the gem has no policy feature and needs none: the Role component stays a
  # generic `name`, and what "owner" or "manager" *means* for a company lives
  # here, never on the component (architecture §1: a component knows no entity
  # subclass).
  class CompanyPolicy
    ROLES = {
      "owner"   => %i[manage_products manage_employees].freeze,
      "manager" => %i[manage_products].freeze,
      "staff"   => [].freeze
    }.freeze

    attr_reader :role

    def initialize(user, company)
      employment = user && company.employments.with_related(:user, user).includes_components(Role).first
      @role = employment&.role_name
    end

    def employee? = role.present?

    def can?(action)
      ROLES.fetch(role, []).include?(action)
    end
  end
end
