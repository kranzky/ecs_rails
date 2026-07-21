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

    full = [user.name.first, user.name.last].compact.join(" ")
    full.presence || "Anonymous"
  end

  # Initials for the avatar chip.
  def initials_for(user)
    return "?" if user.nil?

    parts = [user.name.first, user.name.last].compact
    return "?" if parts.empty?

    parts.map { |p| p[0] }.join.upcase
  end

  # A round avatar chip. Uses the Avatar component's url if set, else initials.
  def avatar_for(user, klass: "avatar")
    url = user&.avatar&.url
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
    entity.likes.count || 0
  end
end
