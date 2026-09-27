class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :acting_user

  private

  # The demo has no accounts. A visitor picks who to act as from the bar under
  # the navigation (ActingAsController), and that person writes the posts,
  # comments and reviews, fills the basket and asks the seller policy for
  # permission. The choice lives in the session; without one, or once an
  # hourly reset has deleted that person, it falls back to the first person
  # in the seed (Ada). This is a convenience, not authentication: anyone can
  # act as anyone.
  def acting_user
    return @acting_user if defined?(@acting_user)

    @acting_user = User.find_by(id: session[:acting_as_id]) || User.order(created_at: :asc, id: :asc).first
  end

  # ECS-31: normalize before querying an offset. Kaminari owns the page/count
  # behavior; an out-of-range bookmark lands on the last available page.
  # Call before preloading so only the chosen page allocates component rows.
  def paginate_list(scope, param: :page)
    value = params[param].to_s
    number = value.match?(/\A[1-9][0-9]{0,8}\z/) ? value.to_i : 1
    page = scope.page(number)
    page.out_of_range? ? scope.page([page.total_pages, 1].max) : page
  end

  # This is a public demo — anyone can post — so cap incoming text lengths
  # server-side (the form `maxlength` only stops honest users). Trims and
  # truncates; nil stays nil.
  def cap(value, limit)
    return value if value.nil?

    value.to_s.strip.first(limit)
  end
end
