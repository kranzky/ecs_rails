# frozen_string_literal: true

# "How this works" panels (ECS-45): beside an interaction, the entity's own
# declarations and the rows that hold it, for a visitor who wants to look
# under the page. Closed by default, so the ordinary flow shows no internals.
#
# The rows are the ones the page has already loaded, never fetched for the
# panel: a slot whose association is loaded is shown as its row (or as no row,
# when the component is virtual), and a slot the page never read says so. That
# keeps every page's query count where ECS-38 pinned it, and it is honest about
# laziness — a slot nobody asked for costs nothing, not even a SELECT. The
# panel therefore renders at the end of the section it explains, after the
# view has read what it shows.
#
# Demo-only on purpose: this inspects any entity through public API
# (`component_declarations`, `association(name)`), but it is not the generic
# component-rendering API that ECS-21 keeps deferred.
module HowThisWorksHelper
  # The lines of an entity class body that compose it.
  DECLARATION = /\A\s*(component|relates_to|has_many|has_one|marker)\b/

  # Every component table has these; they say nothing about this entity.
  BOOKKEEPING = %w[id entity_id slot created_at updated_at].freeze

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # One line of the row illustration: the table and slot a declaration stores
  # in, and what this page knows about its row — :row (with its values),
  # :virtual (loaded, absent: reads give the column defaults) or :unread.
  SlotRow = Data.define(:table, :slot, :reader, :state, :values)

  # The class's declarations as written in its source file, comments and all,
  # so the panel cannot drift from the code it explains.
  def declaration_source(entity_class)
    path, = Object.const_source_location(entity_class.name)
    lines = File.readlines(path).grep(DECLARATION).map(&:rstrip)
    indent = lines.map { |line| line[/\A */].size }.min.to_i
    [Pathname(path).relative_path_from(Rails.root).to_s, lines.map { |line| line[indent..] }.join("\n")]
  end

  # One SlotRow per declared slot, in declaration order. Reads association
  # state only; nothing here can issue a query.
  def slot_rows(entity)
    entity.class.component_declarations.map do |declaration|
      association = entity.association(declaration.reader_name)
      component = association.target if association.loaded?
      state = if !association.loaded? then :unread
              elsif component&.persisted? then :row
              else :virtual
              end
      values = state == :row ? stored_values(component) : {}
      SlotRow.new(table: declaration.component_class.table_name, slot: declaration.slot,
                  reader: declaration.reader_name, state: state, values: values)
    end
  end

  # The entity's own row: an identity and the model that instantiates it.
  def entity_row_values(entity)
    { "id" => short_value(entity.id), "model" => entity.read_attribute(:model) }
  end

  private

  def stored_values(component)
    component.attributes.except(*BOOKKEEPING).compact.transform_values { |value| short_value(value) }
  end

  # Values as a row shows them, short enough for a phone: an id's first
  # block, and long text or JSON cut to a glance.
  def short_value(value)
    text = value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
    return "#{text.first(8)}…" if text.match?(UUID)

    text.truncate(40, omission: "…")
  end
end
