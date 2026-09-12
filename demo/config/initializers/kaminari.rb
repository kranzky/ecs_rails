# frozen_string_literal: true

# ECS-31: every browsing list uses the same modest size. It is not a request
# parameter, so visitors cannot turn a page into an unbounded export.
Kaminari.configure do |config|
  config.default_per_page = 24
  config.max_per_page = 24
end
