# RFC-0003: ApplicationComponent

**Status:** Ready
**Depends on:** RFC-0001

## Goal

A component is an ordinary ActiveRecord model that belongs to an entity and
knows nothing about entity subclasses.

## Rules

- `Rorecs::Component` subclasses `ActiveRecord::Base`, `abstract_class = true`.
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

`component.entity` returning the correct subclass is the subtle bit. The
`belongs_to` targets the abstract `ApplicationEntity`; the loaded row's `model`
column determines which subclass to instantiate. This is the mirror image of how
`entities.model` is written in RFC-0001, and it must round-trip.
