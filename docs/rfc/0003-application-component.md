# RFC-0003: ApplicationComponent

**Status:** Implemented
**Depends on:** RFC-0001, ADR-0008

## Goal

A component is an ordinary ActiveRecord model that belongs to an entity and
knows nothing about entity subclasses.

## Rules

- `EcsRails::Component` subclasses `ActiveRecord::Base`, `abstract_class = true`.
- Host apps subclass it as `ApplicationComponent`.
- Every component `belongs_to :entity, class_name: "ApplicationEntity"`.
- `entity_id` is required and unique per table (DB-enforced; RFC-0008).
- `component.entity` returns the owning entity, typed as its actual subclass
  (a `Post`, not an `ApplicationEntity`) — resolve via the `model`
  discriminator.
- Components are queried directly and normally: `Email.where(verified: false)`,
  `Likes.where(count: 0)`, scopes, `find_each`.
- A component must never reference an entity subclass constant. The one
  sanctioned exception is a relationship component's `class_name:`
  ([ADR-0006](../adr/0006-relationships-are-plain-components.md)).

## Tests

```ruby
it "belongs to its entity" do
  user = User.create!
  user.email.update!(address: "a@b.com")
  expect(Email.first.entity).to eq user
end

it "returns the entity as its real subclass" do
  expect(Email.first.entity).to be_a User
end

it "is queryable without touching entities" do
  expect(Email.where(verified: false).count).to eq 1
end

it "refuses a second row for one entity" do
  expect { Email.create!(entity: user, address: "x") }
    .to raise_error(ActiveRecord::RecordNotUnique)
end
```

## Non-goals

- The `component` DSL (RFC-0004).
- Laziness (RFC-0006).
- Cross-component queries (`.with` / `.without`) — backlog.

## Notes

`component.entity` returning the correct subclass is the subtle bit, and it is
the bulk of the work here — not an afterthought.

[ADR-0008](../adr/0008-subclass-resolution-on-read.md) settles the mechanism:
override `discriminate_class_for_record` on `EcsRails::Entity` to
`classify.constantize` the `model` column. This is Rails' own STI resolution
hook, applied to a column that is *not* `inheritance_column` — taking the one
piece of machinery we want and none of the rest.

**The round-trip is the risk.** `User.model_name.plural.classify.constantize`
must return `User`. That holds for ordinary names but is not universal:

- **Irregular inflections** — a class whose plural does not invert cleanly.
- **Namespaced classes** — `Blog::Post` → `"blog/posts"` → `?`

Test both explicitly. If the round-trip cannot be made to hold in general, say
so loudly rather than working around it — ADR-0008 records that storing the
class name in a separate column is the fallback, and that fighting the
inflector is the wrong answer.

The `belongs_to` targets the abstract `ApplicationEntity`; the loaded row's
`model` column determines which subclass to instantiate. This is the mirror
image of how `entities.model` is written in RFC-0001.

## Amendment: when the owner is checked (ECS-47, 2026-10-29)

"`entity_id` is required" now has a stated rule for *when* it is checked: on
validation, when `entity_id` is nil or has changed. An unchanged key is not
checked by reading the owner back.

Why it had to be written down: `EcsRails::Component` declared
`belongs_to :entity, optional: false`, and Rails builds that validator from
host settings (`belongs_to_required_by_default`, and since 7.1
`belongs_to_required_validates_foreign_key`) read once, when `belongs_to`
runs. The gem's line runs when the gem is required, before any app's
`load_defaults` applies, so every app got the pre-7.1 validator: an owner
SELECT on each save of a component loaded on its own — a row taken under
`Counter.where(...).lock`, or `Email.find(id).update!`. ECS-40's checkout had to
assign each locked stock row its product to avoid it.

Three options were weighed: build the association late enough to honour each
app's setting; state the 7.1 rule in the gem; or leave it and document the
workaround. The user chose to state it:

```ruby
belongs_to :entity, class_name: "ApplicationEntity", optional: true
validates :entity, presence: { message: :required },
                   if: -> { entity_id.nil? || entity_id_changed? }
```

- **Same in every host**, as this RFC's `optional: false` intended: the rule no
  longer depends on load order or an app's defaults.
- **The skipped read guarded nothing.** Every component table's `entity_id` is
  a foreign key to `entities(id)` with `ON DELETE CASCADE`, so an unchanged key
  cannot point at a missing entity.
- **Errors read as before:** a new component without an owner, or one moved to
  an entity that does not exist, is invalid with `errors[:entity]` =
  `["must exist"]`.
- **Changed for apps on pre-7.1 defaults**, which no longer get the read on
  update either. Nothing they could observe depended on it, given the foreign
  key.

Pinned in `gem/spec/component_spec.rb` ("when the component was loaded without
its owner"), on bare ActiveRecord where the flag keeps its old default. The
demo checkout's workaround is removed, and `demo/spec/checkout_reads_spec.rb`
still holds its reads flat.
