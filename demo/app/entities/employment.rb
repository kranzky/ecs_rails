# frozen_string_literal: true

# Who may act for a Company, and as what. A join entity (ADR-0005) — User ×
# Company × Role — the seller-side twin of the forum's Membership, and the
# same Role component serves both. Being an employee is having one of these;
# the same User is a customer the moment they shop. No Customer or Employee
# subclass exists.
class Employment < ApplicationEntity
  relates_to :user,    User
  relates_to :company, Company
  component Role                      # employment.role_name — owner | manager | staff
end
