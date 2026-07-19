# frozen_string_literal: true

# A component: data and behaviour, owned by exactly one entity.
#
# Methods defined here execute with `self` bound to the component, never the
# entity (ADR-0001), and are delegated onto any entity that declares
# `component Moderator`.
#
# This class must never reference an entity subclass.
class Moderator < ApplicationComponent
end
