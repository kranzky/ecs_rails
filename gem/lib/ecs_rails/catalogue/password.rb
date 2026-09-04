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

      # The one-line class install writes is loaded by every application that
      # installs `core`, bcrypt or not — and under eager_load a raise here would
      # stop the app booting for a component it may never use. So the
      # dependency is checked when the class is *used*: with bcrypt present,
      # `has_secure_password`; without it, the same methods raise a LoadError
      # that says what to add.
      included do
        if EcsRails::Catalogue::Password.bcrypt_available?
          has_secure_password
        else
          %i[password= password_confirmation= authenticate authenticate_password].each do |method|
            define_method(method) do |*|
              raise LoadError, "EcsRails::Catalogue::Password needs the bcrypt gem: add `gem \"bcrypt\"` " \
                               "to your Gemfile and bundle"
            end
          end
        end
      end

      # @return [Boolean] whether bcrypt can be required
      # @api private
      def self.bcrypt_available?
        require "bcrypt"
        true
      rescue LoadError
        false
      end
    end
  end
end
