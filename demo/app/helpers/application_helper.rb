# frozen_string_literal: true

module ApplicationHelper
  # A nav link that marks itself current for styling.
  def nav_link(label, path, active:)
    link_to label, path, "aria-current": (active ? "page" : nil)
  end

  # A user's display name, falling back gracefully — components are lazy, so a
  # freshly created user may have no name row yet.
  def display_name(user)
    return "Unknown" if user.nil?

    user.name.to_s.presence || "Anonymous"
  end

  # Initials for the avatar chip.
  def initials_for(user)
    return "?" if user.nil?

    user.name.initials.presence || "?"
  end

  # A round avatar chip. Uses the Avatar component's url if set, else initials.
  def avatar_for(user, klass: "avatar")
    url = user&.avatar_image_url
    style = url.present? ? "background-image:url(#{url})" : nil
    content_tag :span, (url.present? ? "" : initials_for(user)),
                class: klass, style: style, title: display_name(user)
  end

  # A byline: avatar + name, optionally linking to the profile.
  def byline(user, link: true)
    inner = safe_join([avatar_for(user), content_tag(:span, display_name(user))])
    wrapper = content_tag(:span, inner, class: "byline")
    link && user ? link_to(wrapper, user, class: "byline-link") : wrapper
  end

  def likes_count(entity)
    entity.likes
  end

  # --- marketplace ---------------------------------------------------------

  # A Money as the shop shows it. The demo is USD-only (design §7); the
  # component still stores the code, so anything else is shown with it.
  def price_tag(money)
    money.currency == "USD" ? format("$%.2f", money.amount) : money.to_s
  end

  # Stars for a Rating's integer, or a quiet "not yet rated".
  def stars_for(stars)
    return content_tag(:span, "Not yet rated", class: "stars stars--none") if stars.blank?

    content_tag(:span, ("★" * stars) + ("☆" * (5 - stars)), class: "stars", title: "#{stars} out of 5")
  end

  def listing_badge(product)
    if product.listed?
      content_tag(:span, "Listed", class: "badge badge--pub")
    elsif product.delisted?
      content_tag(:span, "Delisted", class: "badge")
    else
      content_tag(:span, "Draft", class: "badge badge--draft")
    end
  end

  def order_badge(order)
    klass = { "paid" => "badge--pub", "shipped" => "badge--mod", "delivered" => "badge--pub", "cancelled" => "badge--draft" }[order.status]
    content_tag(:span, order.status.capitalize, class: "badge #{klass}")
  end

  # An Address component as lines, or a dash when the slot is virtual.
  def address_block(address)
    lines = address.lines
    lines.empty? ? content_tag(:span, "—", style: "color:var(--faint)") : safe_join(lines, tag.br)
  end

  # A company's logo if it has one, else its initial in a chip.
  def logo_for(company, klass: "avatar")
    url = company.logo_image_url
    style = url.present? ? "background-image:url(#{url})" : nil
    content_tag :span, (url.present? ? "" : company.name.to_s.first), class: klass, style: style, title: company.name
  end

  # --- demo reset countdown -------------------------------------------------

  def resets_enabled?
    Demo::ResetScheduler.enabled?
  end

  def next_reset_at
    Demo::ResetScheduler.next_reset_at
  end

  def reset_interval_minutes
    Demo::ResetScheduler.interval_seconds / 60
  end
end
