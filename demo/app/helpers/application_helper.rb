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

  # A round avatar chip. Uses the avatar Image slot's url if set, else initials.
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

  # --- geocoding (ECS-8) ---------------------------------------------------

  # Where the geocoder stands on one stored address: :unpaired when its owner
  # declares no Geolocation in that slot, :waiting when the pair is missing or
  # older than the address, else :located or :not_found.
  def geocoding_state(address, geolocation)
    return :unpaired unless Demo::Geocoder.paired?(address)
    return :waiting unless Demo::Geocoder.current?(address, geolocation)

    geolocation.geocoded? ? :located : :not_found
  end

  GEOCODING_BADGES = {
    located: ["Located", "badge--pub"],
    waiting: ["Waiting for the geocoder", "badge--mod"],
    not_found: ["Place not found", "badge--draft"],
    unpaired: ["Not paired", ""]
  }.freeze

  def geocoding_badge(state)
    label, klass = GEOCODING_BADGES.fetch(state)
    content_tag(:span, label, class: "badge #{klass}")
  end

  # Simulated coordinates, to five places (about a metre).
  def coordinates_for(geolocation)
    format("%.5f, %.5f", geolocation.lat, geolocation.lng)
  end

  # One line about a paired address, for a profile page: its simulated
  # coordinates, or why there are none. Nothing for an empty (virtual) slot.
  def location_note(address, geolocation)
    return unless address.persisted?

    text = case geocoding_state(address, geolocation)
           when :located then "Located at #{coordinates_for(geolocation)} (simulated)"
           when :not_found then "The simulated gazetteer does not know this place"
           else "Not geocoded yet"
           end
    content_tag(:p, safe_join([text, " · ", link_to("Geocoder", geocoder_path)]), class: "hint", style: "margin:.2rem 0 0")
  end

  # A short name for any entity that owns an address.
  def owner_label(entity)
    case entity
    when User then display_name(entity)
    when Company then entity.name
    when Order then "Order #{entity.order_number}"
    when Invoice then "Invoice #{entity.invoice_number}"
    else entity.class.model_name.human
    end
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
