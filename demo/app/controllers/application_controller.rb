class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # This is a public demo — anyone can post — so cap incoming text lengths
  # server-side (the form `maxlength` only stops honest users). Trims and
  # truncates; nil stays nil.
  def cap(value, limit)
    return value if value.nil?

    value.to_s.strip.first(limit)
  end
end
