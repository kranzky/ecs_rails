# ECS Rails

Compose ordinary Rails models from reusable components. Install their tables
once; add entity types, labelled slots, relationships and markers in Ruby.

> This guide uses the **unreleased 0.3.0 API on main**. Published **0.2.2** has
> the earlier API and does not provide this catalogue. Use the source checkout
> below for this tutorial. The gem version stays unchanged until release.

## Quickstart: a contacts directory

You need Ruby 3.2 or newer, Bundler, Rails 7.1–8.x and a running PostgreSQL
server. Your PostgreSQL role must be able to create databases. Use a new app
and database for this tutorial; the script creates example records each run.

From a directory where you keep projects:

```sh
git clone https://github.com/kranzky/ecs_rails.git
rails new contacts --minimal --database=postgresql
cd contacts
bundle add ecs_on_rails --path ../ecs_rails/gem
```

Install the catalogue, then create and migrate the app's database:

<!-- quickstart:commands install -->
```sh
bin/rails generate ecs_rails:install --sets core commerce
bin/rails db:create db:migrate
```

The generator writes `ApplicationEntity`, `ApplicationComponent`, catalogue
classes and an initializer under `app/entities` and `config/initializers`.
Components are top-level constants even though their files live in
`app/entities/components`. The install migration creates the selected catalogue
tables. This tutorial selects `core commerce` to include Money; omitting
`--sets` installs just `core`.

Generate the three entity classes from installed components:

<!-- quickstart:commands entities -->
```sh
bin/rails generate ecs_rails:entity Contact name email home:address avatar:image
bin/rails generate ecs_rails:entity Company name:text email
bin/rails generate ecs_rails:entity Note body:text
```

The generator writes only Ruby classes. Add the marker and inverse relationship
to **app/entities/contact.rb**, so its declarations read:

<!-- quickstart:file app/entities/contact.rb -->
```ruby
class Contact < ApplicationEntity
  component Name
  component Email
  component Address, prefix: :home
  component Image, prefix: :avatar
  marker :featured
  has_many :notes, via: :author
end
```

The generated **app/entities/company.rb** is ready to use. A company's name is a labelled Text, while
Name holds a person's given/family names:

<!-- quickstart:file app/entities/company.rb -->
```ruby
class Company < ApplicationEntity
  component Text, prefix: :name
  component Email
end
```

Add `relates_to :author, Contact` to **app/entities/note.rb**. Links use an
installed shared table:

<!-- quickstart:file app/entities/note.rb -->
```ruby
class Note < ApplicationEntity
  component Text, prefix: :body
  relates_to :author, Contact
end
```

Create **app/services/email_directory.rb** (create the directory too). A system
is just Ruby operating on components. This one reads addresses from any entity
type without knowing Contact or Company:

<!-- quickstart:file app/services/email_directory.rb -->
```ruby
class EmailDirectory
  def self.call
    Email.where.not(address: nil).order(:address).distinct.pluck(:address)
  end
end
```

Create **script/quickstart.rb**:

<!-- quickstart:file script/quickstart.rb -->
```ruby
contact = Contact.create!
puts contact.email.persisted?          # false: a virtual component
puts contact.email.verified            # false: its column default

contact.update!(name_given: "Ada", name_family: "Lovelace",
                email_address: "ada@example.test", home_address_country: "AU")
contact.add(:featured)
contact.notes.create!(body: "Met at Ruby meetup")
Company.create!(name: "Analytical Engines", email_address: "hello@example.test")

puts contact.name.initials             # AL: behavior on the component
puts contact.notes.sole.body           # Met at Ruby meetup
puts Contact.with_component(Address, prefix: :home, country: "AU").count # 1
puts Contact.with_marker(:featured).count # 1
puts EmailDirectory.call              # ada@example.test, then hello@example.test
```

Run it:

<!-- quickstart:commands run -->
```sh
bin/rails runner script/quickstart.rb
bin/rails zeitwerk:check
```

There is still one migration. `name_given` delegates to `name.given`;
`home_address_country` delegates to the labelled Address. A primary attribute
also gets the bare slot name: `note.body` is the string, `note.body_text` is
its component. The relationship reader `note.author` returns a Contact or nil.

### Render the directory

Create **app/controllers/contacts_controller.rb**:

<!-- quickstart:file app/controllers/contacts_controller.rb -->
```ruby
class ContactsController < ApplicationController
  def index
    @contacts = Contact.order(:id).preload(:name, :email)
  end
end
```

Create **app/views/contacts/index.html.erb**:

<!-- quickstart:file app/views/contacts/index.html.erb -->
```erb
<h1>Contacts</h1>
<% @contacts.each do |contact| %>
  <p><%= contact.name_given %>: <%= contact.email_address %></p>
<% end %>
```

Replace **config/routes.rb**:

<!-- quickstart:file config/routes.rb -->
```ruby
Rails.application.routes.draw do
  root "contacts#index"
end
```

Run `bin/rails server` and open <http://localhost:3000>. You should see
**Ada: ada@example.test**. For a larger working application, follow the
[demo setup](https://github.com/kranzky/ecs_rails/blob/main/demo/README.md).

## Generating more entities

After installing and migrating, this command writes `app/entities/person.rb`:

<!-- entity:commands person -->
```sh
bin/rails generate ecs_rails:entity Person name email mobile:phone work:phone home:address
```

```ruby
class Person < ApplicationEntity
  component Name
  component Email
  component Phone, prefix: :mobile
  component Phone, prefix: :work
  component Address, prefix: :home
end
```

References name **existing component classes**, not database column types.
`name` or `Name` selects the default slot; `home:address` selects an Address
labelled `home`. Use `/` or `::` for namespaces, such as `CRM/Person` and
`billing/contact_email`. The entity goes under the configured `entities_path`;
components resolve through the app's normal autoloading, including renamed or
bespoke classes. Namespaced output uses absolute component references.

Missing components produce install/upgrade/`--sets` guidance and the bespoke
component escape hatch. Invalid references and duplicate component/slot pairs
fail before writing. Other method/delegation conflicts are reported by the DSL
when the class loads; edit ordinary Ruby for `only:`, `except:`, slot options,
relationships and markers. Run `bin/rails zeitwerk:check` after editing.

Existing files use Rails/Thor's conflict handling; `--skip` preserves them,
`--force` overwrites, and `--pretend` previews. `bin/rails destroy ecs_rails:entity
Person` removes the generated file, not its database records. The generator emits
no migration, component file or empty spec.

## Presence, values and query costs

An absent component reader returns a virtual object with database column
defaults. **A first read on a saved entity may issue a SELECT even when no row
exists.** The reader caches the result; preloading can avoid per-entity reads.
`contact.avatar_image.persisted?` is false until that slot has a stored row.
`contact.has?(Image, prefix: :avatar)` checks persisted presence; a virtual
object's Ruby truthiness does not imply presence.

Saving an entity persists touched components whose values differ from defaults.
An untouched virtual component skips validation; touched components validate and
merge errors onto the entity. `save` returns false for invalid input, and `save!`
raises `ActiveRecord::RecordInvalid`. Blank strings differ from nil defaults;
normalize optional form fields with `.presence` when blank should mean absent.
Changing a persisted component back to defaults does not automatically delete it.

`with_component` and `without_component` filter **stored rows**, not virtual
values. For example, a virtual Counter reads zero but does not match a query for
a stored Counter with `count: 0`. Component queries need not be declared on the
entity and can match independently stored rows. Markers make presence explicit:
`add(:featured)`, `remove(:featured)` and `featured?`.

Use ordinary Rails association preloads for the slots a page reads, as the
controller above does. `includes_components(Address)` loads all declared Address
slots. Relationship targets can be nested with
`Note.preload(author_relationship: { target: :name })`. See the
[performance comparison](https://github.com/kranzky/ecs_rails/blob/main/docs/design/performance-comparison.md)
for measured costs.

## Updating, replacing and deleting

Prefer reader updates followed by an entity save:

```ruby
contact.email.assign_attributes(address: "new@example.test")
contact.save!
# Equivalent delegated update:
contact.update!(email_address: "new@example.test")
```

| Component operation | Behavior |
| --- | --- |
| `contact.email` | Returns a cached component, possibly virtual. |
| `contact.email = Email.new(address: "replacement@example.test")` | Replaces atomically and immediately on a saved owner; waits for owner save on a new owner. Default-only replacements remain virtual. |
| `contact.email = nil` | Removes the row; the next reader returns a virtual component. |
| `contact.reload_email` / `contact.reset_email` | Discard both component and association caches. Reload reads immediately; reset defers the read. |
| `contact.build_email`, `create_email`, `create_email!` | Intentionally raise `EcsRails::InvalidComponent`; use the reader or delegated update. |

Replacement preserves the original row if validation fails, raising
`ActiveRecord::RecordInvalid` on a saved owner. Wrong types, another owner's
component and moving a persisted component between slots are rejected. After
an outer transaction rolls back, reload the owner before using its cached state.
Raw association mutation and validation-bypassing writes are outside this contract.

**Relationships.** `note.author = Contact.new(...)` saves that new target, its
touched components and the link in the owner's transaction when `note.save!`
runs. An invalid target prevents the save. Wrong-type objects raise on assignment;
wrong-type or missing IDs fail validation, exposed under
`note.errors["author_relationship.target"]`. Nil is allowed; reading an unset
link or assigning then clearing a new target creates no target or link row.
Targets accept subclasses of the declared class. The foreign key protects
existence, but writes bypassing validation also bypass the Ruby target-type check.

**Deletion.** Destroying an entity deletes its component rows through PostgreSQL
`ON DELETE CASCADE`, bypassing those components' destroy callbacks. Explicit
`contact.email.destroy` runs component destroy callbacks and resets the owner
reader to virtual defaults. Replacement also runs the old component's destroy
callbacks, then makes the replacement available through the reader. Destroying a relationship's
target nullifies `target_id`; reload a previously cached owner to observe it.
The referring entity survives.

Inverse collection APIs such as `contact.notes.create!` are supported Rails
associations. Deleting from an inverse collection removes the **link**, not the
child entity. `dependent: :destroy` / `:delete_all` on an inverse also applies to
link rows. To destroy the notes themselves, explicitly call
`contact.notes.each(&:destroy)` before destroying the contact. Choose this in the
application: invoices, for example, may need to survive their former owner.

## When another migration is needed

“Zero migrations” means **composition from the installed catalogue**. New slots,
markers and entity types reuse those tables. New catalogue schema versions and
bespoke storage still need migrations.

For a bespoke temperature reading, run:

<!-- bespoke:commands install -->
```sh
bin/rails generate ecs_rails:component Temperature celsius:decimal
bin/rails db:migrate
```

Inspect the generated migration before running it; decimal precision, scale and
defaults are application choices. The generator also writes a model and an
RSpec example (running that spec requires an RSpec Rails setup). Create
**app/entities/weather_station.rb**:

<!-- bespoke:file app/entities/weather_station.rb -->
```ruby
class WeatherStation < ApplicationEntity
  component Temperature
end
```

Create **script/temperature.rb**:

<!-- bespoke:file script/temperature.rb -->
```ruby
station = WeatherStation.create!(temperature_celsius: 21.5)
puts station.reload.temperature.celsius # 21.5
```

<!-- bespoke:commands run -->
```sh
bin/rails runner script/temperature.rb
bin/rails zeitwerk:check
```

This app now has a second migration and a dedicated `temperatures` table.

## Upgrading an existing installation

Back up the database and try the upgrade on a copy first. For published 0.2.2,
change the Gemfile entry to the source path above, then run `bundle update
ecs_on_rails`. Use development (without eager loading) for generation: an old
app needs the new generated classes before it can fully boot. Set
`RAILS_ENV=development` in your shell, then run:

<!-- upgrade:commands generate -->
```sh
bin/rails generate ecs_rails:upgrade
```

Choose `--sets core commerce` if the app needs Money. Review the generated
migrations, then run:

<!-- upgrade:commands migrate -->
```sh
bin/rails db:migrate
```

The upgrade moves old relationship backing tables and marker rows into shared
tables, preserving their IDs and links. Replace old marker declarations such as
`component Moderator` with `marker :moderator`, update `add(Moderator)` /
`remove(Moderator)` calls to symbols, and remove the obsolete marker class file
after migration. Review the generator's output for your app's names. Bespoke
components remain; do not remove their classes.

<!-- upgrade:commands verify -->
```sh
bin/rails zeitwerk:check
bin/rails generate ecs_rails:upgrade
```

Also run your application's tests. Repeating the generator on the completed
schema should produce no new migration. Upgrade checks column definitions,
unique/partial indexes and foreign keys before writing files. Incompatible
structures need an explicit repair/backfill migration; the generator does not
convert values or silently replace constraints. New constraints validate existing
rows when the migration runs. See the
[upgrade design](https://github.com/kranzky/ecs_rails/blob/main/docs/rfc/0017-catalogue.md).

## Compatibility checks

The gem requires Ruby >= 3.2 and Rails >= 7.1, < 9. The representative CI matrix
covers Ruby/Rails 3.2/7.1, 3.2/7.2, 3.3/8.0, 3.2/8.1, 3.4/8.1 and 4.0/8.1,
resolving current patches within each Rails minor. It runs PostgreSQL gem specs
and packaged fresh-install/0.2.2-upgrade checks for each entry. The package
check extracts the marked code and Rails command blocks from this README,
then verifies the tutorial's stored results, rendered page and bespoke component. The demo suite,
eager loading and a 100% public-API documentation gate run separately.

JSON is constrained to version 2 because supported Rails decoders still use
positional option hashes incompatible with JSON 3. This is a runtime dependency,
so a packaged consumer receives the same constraint as the test suite.

To reproduce a Rails series locally from `gem/`:

```sh
export BUNDLE_GEMFILE="$PWD/gemfiles/rails_7.1.gemfile"
bundle install
DATABASE_URL=postgresql:///ecs_rails_test bundle exec rspec
DATABASE_URL=postgresql:///ecs_rails_test bundle exec ruby script/package_smoke.rb
```

The package smoke script creates its own uniquely named PostgreSQL databases;
its connection role needs permission to create databases. It removes only those
databases after the run. CI uploads each built gem with its resolved dependency
lockfile. This tests released versions, not future Ruby/Rails releases.

## Documentation

- **[Architecture](https://github.com/kranzky/ecs_rails/blob/main/docs/architecture.md)** — the invariants and design background.
- **[v0.1 retrospective](https://github.com/kranzky/ecs_rails/blob/main/docs/retrospective-v0.1.md)** — what was built, what
  the demo found, what's next.
- **[Source walkthrough](https://github.com/kranzky/ecs_rails/blob/main/docs/source-walkthrough.md)** — follow composition, validation, checkout and indexing through the code.
- **[ADRs](https://github.com/kranzky/ecs_rails/tree/main/docs/adr)** — why the design is the way it is.
- **[RFCs](https://github.com/kranzky/ecs_rails/tree/main/docs/rfc)** — feature contracts and their amendments.
- **[Backlog](https://github.com/kranzky/ecs_rails/blob/main/docs/backlog.md)** — what deliberately isn't built yet.
- **[Friction log](https://github.com/kranzky/ecs_rails/blob/main/docs/friction-log.md)** — the demo's running verdict on
  the API.

## Development

Requires Ruby >= 3.2 and a running PostgreSQL.

```sh
createdb ecs_rails_test
bundle install
bundle exec rspec
```

Set `DATABASE_URL` to point the suite at a different database.

## Names

`ecs_rails` everywhere except the Gemfile — see
[ADR-0007](https://github.com/kranzky/ecs_rails/blob/main/docs/adr/0007-monorepo-and-licensing.md#three-different-names).

| | |
|---|---|
| GitHub repo | [`ecs_rails`](https://github.com/kranzky/ecs_rails) |
| RubyGems gem | `ecs_on_rails` |
| Ruby module | `EcsRails` |
| `require` | `ecs_rails` |
| Generators | `ecs_rails:install`, `:component`, `:entity`, `:upgrade` |

Only the published gem name differs. RubyGems collapses `-`, `_` and case when
comparing names, so `ecs-rails`, `ecs_rails` and `ecsrails` are one name — and
it belongs to an unrelated, still-maintained gem. `ecs_on_rails` keeps the
`rails` keyword without the `rails-` prefix that convention reserves for Rails
Core Team gems.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
