# frozen_string_literal: true

module EcsRails
  # Generator configuration for the directory layout (ADR-0010).
  #
  # The gem RUNTIME never reads this: entities and components are keyed by class
  # name (RFC-0002) and by the `model` discriminator (ADR-0002), so the registry
  # does not care where a class file lives. This object exists purely so the
  # generators (RFC-0008) know where to write, and so the initializer they emit
  # can echo the chosen path.
  #
  # `entities_path` is the single knob. Components always live in a `components`
  # subdirectory of it, which is why `components_path` is derived rather than
  # separately settable — ADR-0010 deliberately exposes one path, not two.
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

    def initialize
      @entities_path = "app/entities"
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
