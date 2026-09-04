# frozen_string_literal: true

module EcsRails
  module Catalogue
    # A password digest, via `has_secure_password` (Rails 8's generated
    # authentication, from the catalogue). Requires the `bcrypt` gem in the
    # application, as `has_secure_password` always does.
    #
    #   user.password.password = "s3cret"; user.save!   # stores a digest
    #   user.password.authenticate("s3cret")            # => the component, or false
    #
    # A `Session` entity is `Token` + `Timestamp` + `relates_to :user`.
    module Password
      extend Definition

      table "passwords"
      schema do |t|
        t.string :password_digest, default: nil
      end

      included do
        begin
          require "bcrypt"
        rescue LoadError
          raise LoadError, "EcsRails::Catalogue::Password needs the bcrypt gem: add `gem \"bcrypt\"` to your Gemfile"
        end
        has_secure_password
      end
    end
  end
end
