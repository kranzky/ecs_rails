# frozen_string_literal: true

require "securerandom"
require "digest"
require "active_support/core_ext/securerandom"
require "active_support/security_utils"

module EcsRails
  module Catalogue
    # A single-use secret: password reset, invitation, API key — one slot each.
    # Stores a **digest**, never the value (the `generates_token_for` shape):
    # generate once, show once, verify against the digest.
    #
    #   raw = user.reset_token.generate!(expires_in: 1.hour)   # give this to the user
    #   user.reset_token.verify(raw)                           # => true, once, until it expires
    module Token
      extend Definition

      table "tokens"
      schema do |t|
        t.string   :digest,     default: nil
        t.datetime :expires_at, default: nil
        t.index :digest
      end

      # Generates a fresh value, stores its digest and saves. Returns the value
      # — the only time it is available.
      #
      # @param expires_in [ActiveSupport::Duration, nil] nil for no expiry
      # @return [String] the raw token
      def generate!(expires_in: nil)
        raw = SecureRandom.base58(32)
        update!(digest: self.class.ecs_digest(raw), expires_at: expires_in && Time.current + expires_in)
        raw
      end

      # @param raw [String]
      # @return [Boolean] whether `raw` matches and the token has not expired
      def verify(raw)
        return false if digest.nil? || raw.nil? || expired?

        ActiveSupport::SecurityUtils.secure_compare(digest, self.class.ecs_digest(raw))
      end

      # @return [Boolean]
      def expired?
        expires_at.present? && expires_at <= Time.current
      end

      # Forgets the token.
      #
      # @return [void]
      def revoke!
        update!(digest: nil, expires_at: nil)
      end

      included do
        # @api private
        def self.ecs_digest(raw)
          Digest::SHA256.hexdigest(raw)
        end

        # The row for a raw token, if any (then `verify` it).
        #
        # @param raw [String]
        # @return [ActiveRecord::Base, nil]
        def self.find_by_token(raw)
          find_by(digest: ecs_digest(raw))
        end
      end
    end
  end
end
