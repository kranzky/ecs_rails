# frozen_string_literal: true

raise "Expected install plus bespoke migration" unless Rails.root.glob("db/migrate/*.rb").size == 2
station = WeatherStation.sole
raise "Bespoke value did not persist" unless station.temperature.celsius == BigDecimal("21.5")
raise "Bespoke ownership lost" unless station.temperature.entity_id == station.id
station.destroy!
raise "Bespoke foreign key did not cascade" if Temperature.exists?
puts "README bespoke component persisted a decimal and cascaded with its owner."
