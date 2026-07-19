# frozen_string_literal: true

# A component: data and behaviour, owned by exactly one entity (ADR-0001).
class Email < ApplicationComponent
  validates :address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  def send_welcome_email
    # In a real app, enqueue a mailer. self is the Email, never the entity.
    :sent
  end
end
