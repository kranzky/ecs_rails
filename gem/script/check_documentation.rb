# frozen_string_literal: true

# YARD stats itself exits successfully when methods lack documentation. Make
# its per-category undocumented counts an actual CI gate, retaining its report.
require "open3"
output, status = Open3.capture2e(RbConfig.ruby, "-S", "yard", "stats", "--list-undoc")
puts output
counts = output.scan(/\(\s*(\d+) undocumented\)/).flatten.map(&:to_i)
abort "YARD must report zero undocumented objects in every category." unless status.success? && counts.any? && counts.all?(&:zero?)
