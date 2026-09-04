# frozen_string_literal: true

module EcsRails
  # Configuration: the generator directory layout (ADR-0010) and the name of
  # the host app's `Relationship` component (ADR-0017).
  #
  # The layout half is generator-only: entities and components are keyed by
  # class name (RFC-0002) and by the `model` discriminator (ADR-0002), so the
  # registry does not care where a class file lives; the generators (RFC-0008)
  # read it to know where to write, and the initializer they emit echoes it.
  #
  # `entities_path` is the single layout knob. Components always live in a
  # `components` subdirectory of it, which is why `components_path` is derived
  # rather than separately settable — ADR-0010 deliberately exposes one path,
  # not two.
  #
  # `relationship_class_name` IS read at runtime — by `relates_to`, on every
  # call, so a reloaded constant is picked up. It exists for the one app whose
  # domain already has a `Relationship`; everyone else leaves the default.
  # @example Restoring the pre-ADR-0010 single-directory layout
  #   # config/initializers/ecs_rails.rb
  #   EcsRails.configure { |config| config.entities_path = "app/models" }
  #
  # @see EcsRails.configure
  class Config
    # Entities land here; the default is the ADR-0010 layout. Set it to
    # `"app/models"` to restore the pre-ADR-0010 single-directory layout.
    #
    # @return [String] the directory entities are generated into
    attr_accessor :entities_path

    # The host app's catalogue component that backs every `relates_to`
    # (EcsRails::Catalogue::Relationship, ADR-0017). `rails g ecs_rails:install`
    # writes it as `Relationship`; rename here only if that constant is taken.
    #
    # @return [String] the class name, resolved by `constantize` at each use
    attr_accessor :relationship_class_name

    def initialize
      @entities_path = "app/entities"
      @relationship_class_name = "Relationship"
    end

    # Components live in a `components` subdirectory of the entities path. The
    # generated initializer collapses this directory so Zeitwerk treats the
    # `components/` segment as transparent (ADR-0010 "How it works").
    #
    # Derived rather than separately settable: ADR-0010 deliberately exposes one
    # path, not two.
    #
    # @return [String] the directory components are generated into,
    #   e.g. `"app/entities/components"`
    def components_path
      "#{entities_path}/components"
    end
  end
end
