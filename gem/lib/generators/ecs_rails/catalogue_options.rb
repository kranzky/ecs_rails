# frozen_string_literal: true

require "ecs_rails"

module EcsRails
  module Generators
    # The `--sets` and `--rename` options install and upgrade share (ADR-0018),
    # and the one-line catalogue class writer they both use.
    module CatalogueOptions
      def self.included(base)
        # The one-line class template is shared by install and upgrade, so it
        # lives beside this file rather than in either generator's templates.
        base.source_paths << File.expand_path("templates", __dir__)
        base.class_option :sets, type: :array, default: %w[core],
                                 desc: "Catalogue sets to install (#{EcsRails::Catalogue.sets.join(', ')}, or all)"
        base.class_option :rename, type: :array, default: [],
                                   desc: "Rename catalogue classes, e.g. money:Price text:Copy"
      end

      private

      # The sets asked for, as Symbols, validated against the catalogue.
      def sets
        @sets ||= options[:sets].flat_map { |s| s.split(",") }.map { |s| s.strip.to_sym }.tap do |names|
          EcsRails::Catalogue.in_sets(*names) # raises on an unknown set
        end
      end

      # The catalogue components in the selected sets, in catalogue order.
      def catalogue_components
        @catalogue_components ||= EcsRails::Catalogue.in_sets(*sets)
      end

      # `--rename money:Price text:Copy` as `{ money: "Price", text: "Copy" }`.
      def renames
        @renames ||= options[:rename].flat_map { |r| r.split(",") }.to_h do |pair|
          from, to = pair.split(":", 2)
          raise Thor::Error, "--rename expects name:ClassName pairs, got #{pair.inspect}" if from.blank? || to.blank?
          raise Thor::Error, "--rename: no catalogue component named #{from.inspect}" unless EcsRails::Catalogue[from]

          [EcsRails::Catalogue[from].catalogue_name, to]
        end
      end

      # The application class name for a catalogue component, renames applied.
      def class_name_for(component)
        renames.fetch(component.catalogue_name, component.class_name)
      end

      # Writes one one-line class per component, skipping files that exist —
      # upgrade must not clobber an app's own edits, and a re-run of install is
      # idempotent.
      def create_catalogue_class_files(components)
        components.each do |component|
          @component = component
          @class_name = class_name_for(component)
          template "catalogue_class.rb.tt",
                   File.join(EcsRails.config.components_path, "#{@class_name.underscore}.rb"),
                   skip: true
        end
      end

      attr_reader :component, :class_name
    end
  end
end
