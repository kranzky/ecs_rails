# Grouping same-type slots into one preload query (ECS-41)

## Decision — 26 October 2026: deferred

`includes_components` stays what [ADR-0012](../adr/0012-component-preloading.md)
made it: a thin wrapper over ActiveRecord's own `preload`, one query per
declared slot. Loading each component *type* once would be faster, but on the
demo's ordinary pages it saves about one query and a millisecond, and the case
where it saves a lot — a page showing many slots of one type — is already
better served by naming the slots a page shows (ECS-38). The prototype and
its measurements are kept so the question can be reopened with numbers.

Revisit when either of these holds:

- a real page lists records and shows **four or more slots of one component
  type** on each, where named preloads would still issue one query per slot;
- Rails can use `available_records` (or a successor) for **scoped**
  associations, which would make grouping a documented preloader feature
  rather than gem code.

## The question

Every slot is a slot-scoped `has_one` (`-> { where(slot: "title") }`), so
`includes_components(Text)` on a Product with six Text slots runs six queries
against `texts`, one per slot, plus the owners. Could the gem fetch an
entity type's rows of one component type in one query and hand each slot its
row, behind the same API?

## What Rails offers

The documented extension point is `ActiveRecord::Associations::Preloader`'s
`available_records:` — records already loaded that the preloader may use
instead of querying. It cannot serve component slots: in Rails 8.1.3,
`Preloader::Association#associate_records_from_unscoped` returns early when
`!reflection_scope.empty_scope?`, and every component `has_one` has a scope.
Rails does batch preload queries itself, but only for loaders whose scopes are
identical (`LoaderQuery#eql?` compares `values_for_queries`), and two slots
never are.

So grouping means gem code doing a preloader's job: query once, then write
each owner's row into each slot's association. The prototype needs one
`:nodoc:` ActiveRecord API, `record.association(name).target =` — the gem
already relies on it in `Lazy::Entity#ecs_forget_component` — and otherwise
public API: `row.entity = owner` to give the row its owner, and a relation
`extending` module overriding `load` to run after the records arrive.

## The prototype

[`demo/script/grouped_preload_experiment.rb`](../../demo/script/grouped_preload_experiment.rb):

```ruby
def grouped_preload(owners, *component_classes)
  ids = owners.map(&:id)
  component_classes.each do |klass|
    declarations = owners.first.class.component_declarations.select { |d| d.component_class == klass }
    rows = klass.where(entity_id: ids, slot: declarations.map { |d| d.slot.to_s }).group_by { |r| [r.entity_id, r.slot] }
    owners.each do |owner|
      declarations.each do |d|
        row = rows[[owner.id, d.slot.to_s]]&.first
        owner.association(d.reader_name).target = row # the :nodoc: internal
        row.entity = owner if row # public writer: the row knows its owner
      end
    end
  end
  owners
end
```

It covers one entity type per call and no nesting. Each measurement first
checks that the prototype's projected values equal `includes_components`'s.

## Measurements

Apple M1 Pro, Ruby 3.4.5, Rails 8.1.3, PostgreSQL 17.11, the gem's source at
`d2663fb`. 200 warm runs each, relation load plus the projection a page would
read, in one process; medians and p95 in milliseconds. Rails 8.1 only: the
deferred decision did not need the matrix.

**Stress fixture** — 24 products, each with six Text and six Counter slots
(the ECS-33 benchmark's shape), reading every slot:

| Path | Reads | p50 | p95 | Allocations |
|---|---:|---:|---:|---:|
| `includes_components(Text, Counter)` | 13 | 19.53 | 28.49 | 13,314 |
| grouped prototype | 3 | 10.06 | 11.65 | 7,979 |
| `preload(:title_text, :stock_counter)`, reading two slots | 3 | 5.21 | 7.18 | 2,865 |

**The demo's remaining type-wide list preloads**, on its seed data:

| Page's preload | Reads current / grouped | p50 current / grouped | Allocations current / grouped |
|---|---:|---:|---:|
| Posts: Text ×2, Counter | 4 / 3 | 4.54 / 3.73 | 1,807 / 1,157 |
| People: Name, Email, Image, Marker ×2 | 6 / 5 | 5.26 / 4.20 | 2,593 / 1,618 |
| Sellers: Text ×2, Image, Address | 5 / 4 | 4.33 / 3.57 | 1,966 / 1,164 |

On the demo pages grouping saves the one extra slot query and 0.8–1.1 ms of
preload work; the posts and people pages render in about 13.4 and 9.7 ms
whole (ECS-38's page run), so 6–11% of a page. Allocations fall by 36–41%,
more than one query explains: most of that is Rails' preloader machinery,
which builds loader objects per association, even for types with one slot.

## Why deferred

- **The win that matters is already available.** A page that shows a few of
  many slots should name them (ECS-38), which takes about half the grouped
  prototype's time.
  Grouping only wins outright when a page shows most slots of a type, and no
  demo page does.
- **The everyday gain is small.** One query and about a millisecond on pages
  of ten to fifteen.
- **It would be a second preloader.** `includes_components` would stop being
  native `preload` and start owning association loading: relation chaining,
  batches (`find_each`), interaction with a `preload` of the same names,
  strict loading, nested relationship preloads alongside it, cache coherence
  after replacement and reload, and equivalence on every supported Rails
  series (7.1, 7.2, 8.0, 8.1). Each is testable; together they are a
  maintenance surface ADR-0012 chose not to have.
- **It deepens reliance on `association(name).target=`,** an internal the gem
  uses in one place today.

The allocation finding is the most interesting result: some of the cost of a
type-wide preload is Rails' preloader itself, not the queries. If a future
issue needs it, the prototype above is the starting point.
