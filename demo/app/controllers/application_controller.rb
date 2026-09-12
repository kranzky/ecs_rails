class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

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
