# frozen_string_literal: true

class MemberGroup < ApplicationComponent
  belongs_to :group, class_name: "Group", foreign_key: :group_id, optional: true
end
