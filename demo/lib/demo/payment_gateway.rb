# frozen_string_literal: true

module Demo
  # Payment, simulated: no network, no keys, no secrets (design §7). A card
  # number is 12–19 digits; one magic number declines so the checkout's
  # rollback can be exercised on demand.
  module PaymentGateway
    class Declined < StandardError; end

    DECLINED = "4000000000000002"

    module_function

    def charge!(money, card_number:)
      digits = card_number.to_s.delete("^0-9")
      raise Declined, "the card number is not valid" unless (12..19).cover?(digits.size)
      raise Declined, "the card was declined" if digits == DECLINED
      raise Declined, "nothing to charge" if money.zero?

      "ch_#{Digest::SHA256.hexdigest("#{digits}:#{money.amount_cents}:#{Time.current.to_i}")[0, 16]}"
    end
  end
end
