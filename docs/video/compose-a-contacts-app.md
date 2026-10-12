# Video: compose a contacts app and run one cross-entity system

The shooting script for the ECS Rails demo video (Linear ECS-10). One
narrative — **compose → use → inspect → extend** — told with a small contacts
app on the published `ecs_on_rails` 0.3.0. It is the same app, code and names
as the launch post, [The Last Migration](../blog/the-last-migration.md), so a
viewer can follow either and reproduce the other. Depth is left to links: the
[tutorial](../../gem/README.md), the
[marketplace demo](https://ecs-rails.kranzky.com) and the post.

**Target length:** about 8 minutes. **Narration:** about 850 words — six minutes
at an unhurried 140 words a minute — and the rest is typing and pauses on
results.

Every command, file, console line and SQL query below runs as written. The
`verify:` comments mark them for [`docs/blog/verify.rb`](../blog/verify.rb),
which builds a fresh app from RubyGems and replays the whole video:

```sh
ruby docs/blog/verify.rb docs/video/compose-a-contacts-app.md
```

Run it on recording day. If it fails, the video would show something false.

## Before recording

**Machine.** Ruby 3.4 with `gem install rails` (8.1), PostgreSQL running, and
an empty working directory. Remove any earlier take's databases with
`dropdb --if-exists contacts_development` and
`dropdb --if-exists contacts_test`. Run `rails new` once in a scratch
directory beforehand so the gems are cached; the wait is cut in the edit
anyway.

**Terminal.** 18–20 pt monospace, about 100 columns, one colour theme for the
whole video, and a short prompt (`PS1='$ '`). Clear the screen at each scene
change. Keep the console and `dbconsole` in two tabs so the switch is one
keystroke.

**Editor.** The same font size, a single file on screen, no sidebar, no
minimap. The edits are short enough to type live; paste them if a take drags,
but let the viewer see the result settle before speaking over it.

**SQL in the console.** The development console prints every query, which
scene 3 relies on. Rails 8 also appends a `/*application='Contacts'*/` tag to
each one. Off camera, after `rails new`, change
`config.active_record.query_log_tags_enabled = true` to `false` in
`config/environments/development.rb` to shorten the lines. It changes nothing
else, so the viewer's own run differs only by that tag.

**psql.** Start `dbconsole` with `PSQLRC=/dev/null` if your psqlrc turns on
`\timing` or a pager; the output then matches the script.

**Pacing.** Let each result stay on screen for two seconds before the
narration explains it. Every scene below names the result that must be
visible; if it scrolled away, retake.

**Captions.** Upload [the transcript](compose-a-contacts-app.transcript.txt)
alongside the video and let YouTube's auto-sync time it, then check the
technical words (E.164, `dbconsole`, `updated_at`). Regenerate the transcript
after editing any narration:

```sh
awk '/^>( |$)/ { sub(/^> ?/, ""); print; quoted = 1; next }
     quoted    { print ""; quoted = 0 }' \
  docs/video/compose-a-contacts-app.md > docs/video/compose-a-contacts-app.transcript.txt
```

---

## Cold open — 0:00 to 0:20

*Record last, on the finished app; place first.* A terminal, in the finished
`contacts` app. Type `ls db/migrate`; one file appears.

> This Rails app has people and companies, phone numbers, addresses, a
> relationship, a flag, and a system that works across all of it.
> And this is its migrations directory. One file. Let me show you how it got
> here.

Title card: **Compose, don't migrate — ECS Rails 0.3.0**.

## 1. Install — 0:20 to 1:30

**On screen:** a new app, the gem, the install, one migration.

<!-- verify:commands -->
```sh
rails new contacts --minimal --database=postgresql
cd contacts
bundle add ecs_on_rails --version "~> 0.3.0"
bin/rails generate ecs_rails:install
bin/rails db:create db:migrate
```

> I'm starting from nothing: a new Rails app on PostgreSQL. I add the gem,
> ecs_on_rails, and run its install generator. That writes one migration, and
> I run it once.

Pause on the migration output scrolling past, then show what was installed:

<!-- verify:commands -->
```sh
ls app/entities/components
```

<!-- verify:output columns -->
```text
address.rb                link.rb           role.rb
application_component.rb  marker.rb         search_vector.rb
calendar_date.rb          name.rb           state.rb
counter.rb                password.rb       tags.rb
discard.rb                period.rb         text.rb
email.rb                  phone.rb          timestamp.rb
geolocation.rb            position.rb       token.rb
identifier.rb             rating.rb
image.rb                  relationship.rb
```

> The install created a catalogue of components: a name, an email, a phone
> number, an address, a geolocation, text, counters, tags and more. Each is
> a tiny class in my app; the behaviour comes from the gem. And each has
> its own table, already created.

<!-- verify:commands -->
```sh
ls db/migrate
```

<!-- verify:output -->
```text
20261012023722_ecs_rails_install.rb
```

> That's the only migration this app will need.

**Visible result:** the component list, then the single migration file.

## 2. Compose — 1:30 to 3:00

**On screen:** two generator commands, then each file in the editor.

<!-- verify:commands -->
```sh
bin/rails generate ecs_rails:entity Person name email mobile:phone work:phone home:address home:geolocation
bin/rails generate ecs_rails:entity Company name:text phone address geolocation
```

> Now the two kinds of thing in a contacts app. A person is made of a name, an
> email, a mobile phone and a work phone, a home address, and a geolocation
> for that address. A company has a name, a phone, an address and a
> geolocation.

Open `app/entities/person.rb` as generated (the frozen-string comment aside):

```ruby
class Person < ApplicationEntity
  component Name
  component Email
  component Phone, prefix: :mobile
  component Phone, prefix: :work
  component Address, prefix: :home
  component Geolocation, prefix: :home
end
```

> The generator wrote plain Ruby, and nothing else. No migration. "mobile" and
> "work" are slots: two phones in the same phones table, told apart by a slot
> column, each validated on its own.

Type the two new lines at the end of the class:

<!-- verify:file app/entities/person.rb -->
```ruby
class Person < ApplicationEntity
  component Name
  component Email
  component Phone, prefix: :mobile
  component Phone, prefix: :work
  component Address, prefix: :home
  component Geolocation, prefix: :home
  relates_to :employer, Company
  marker :favourite
end
```

> A person works for a company, so I'll add a relationship called employer.
> And I want to star a few people as favourites, so I'll add a marker. Neither
> needs a table: every relationship lives in one shared relationships table,
> and every marker in one markers table. Both came with the install.

Open `app/entities/company.rb` and add the `has_many` line:

<!-- verify:file app/entities/company.rb -->
```ruby
class Company < ApplicationEntity
  component Text, prefix: :name
  component Phone
  component Address
  component Geolocation
  has_many :employees, "Person", via: :employer
end
```

> A company's name isn't a person's name, so it's the generic Text component,
> in a slot called name. And from the company's side, its employees are the
> people whose employer it is: the same rows, read the other way.

**Visible result:** both finished classes, each fitting on one screen.

## 3. Use — 3:00 to 4:45

**On screen:** `bin/rails console`, with its SQL showing.

<!-- verify:console -->
```ruby
ada = Person.create!
ada.email.persisted?  # => false
ada.email.verified    # => false
```

> I create a person. That's one INSERT, into the entities table, and nothing
> else. Ask for her email and I get an Email back, not nil — but it isn't
> saved. It's virtual: every column at its default.

Point at the `Email Load` line.

> Look at the SQL, though. To know Ada has no email, Rails had to ask: one
> SELECT that found nothing. That's the price of composition. The answer is
> cached, and a page listing many people should preload what it shows.

<!-- verify:console -->
```ruby
ada.update!(name_given: "Ada", name_family: "Lovelace",
            email_address: "ada@example.com",
            mobile_phone_e164: "+61491570156",
            home_address_locality: "Perth", home_address_country: "AU")
ada.name.to_s              # => "Ada Lovelace"
ada.mobile_phone.to_s      # => "+61491570156"
ada.work_phone.persisted?  # => false
```

> Now a write. Each component's attributes are delegated with its name in
> front: name given, mobile phone e164, home address country. One update, one
> transaction. In the SQL: three SELECTs for components we hadn't loaded yet,
> then four INSERTs, one per component that now holds something. The work
> phone was never touched, so it's still not a row.

<!-- verify:console -->
```ruby
engines = Company.create!(name: "Analytical Engines",
                          address_locality: "London", address_country: "GB")
ada.update!(employer: engines)
ada.add(:favourite)

engines.name                                          # => "Analytical Engines"
engines.employees.map { |person| person.name.to_s }   # => ["Ada Lovelace"]
ada.favourite?                                        # => true
Person.with_component(Address, prefix: :home, country: "AU").count  # => 1
```

> A company, an employer, a favourite. And a question about composition:
> which people have a home address in Australia? That's a single EXISTS query
> against the addresses table, scoped to people.

**Visible result:** the `Email Load` SELECT, the three-SELECT/four-INSERT
transaction, and the `1`.

## 4. Inspect — 4:45 to 5:45

**On screen:** switch to the second tab and run `bin/rails dbconsole`.

<!-- verify:sql -->
```sql
SELECT entities.model, addresses.slot, addresses.locality, addresses.country
  FROM addresses JOIN entities ON entities.id = addresses.entity_id
 ORDER BY entities.model;
SELECT owner_model, slot FROM relationships;
SELECT slot FROM markers;
```

<!-- verify:output -->
```text
   model   | slot | locality | country
-----------+------+----------+---------
 companies |      | London   | GB
 people    | home | Perth    | AU
(2 rows)

 owner_model |   slot
-------------+----------
 people      | employer
(1 row)

   slot
-----------
 favourite
(1 row)
```

> Here's what that looks like underneath. The addresses table holds Ada's
> home address and the company's address side by side. The table doesn't know
> about people or companies; the owner's model and the slot tell them apart.
> The employer link is one row in relationships, and the favourite is one row
> in markers. Every table here has real columns, a foreign key to its entity,
> and a unique index on entity and slot — so the database itself won't let
> Ada have two mobile phones.

**Visible result:** the three small result sets.

## 5. Extend — 5:45 to 7:30

**On screen:** create `app/systems/geocoder.rb` in the editor. Paste it, then
scroll through it slowly, highlighting each part as it is mentioned.

<!-- verify:file app/systems/geocoder.rb -->
```ruby
# Gives every Address a Geolocation in the same slot, whichever kind of
# entity owns it. PLACES stands in for a geocoding service: approximate
# city centres, and anywhere else is "not found".
class Geocoder
  PLACES = {
    %w[AU Perth]    => [-31.9523, 115.8613],
    %w[GB London]   => [51.5074, -0.1278],
    %w[NZ Auckland] => [-36.8485, 174.7633]
  }.freeze

  def self.call
    Address.preload(:entity).find_each.count { |address| geocode(address) }
  end

  def self.geocode(address)
    owner = address.entity
    return false unless owner.class.declaration_for(Geolocation, prefix: address.slot)

    geolocation = Geolocation.find_or_initialize_by(entity: owner, slot: address.slot)
    return false if geolocation.geocoded_at && geolocation.geocoded_at >= address.updated_at

    lat, lng = PLACES[[address.country, address.locality]]
    geolocation.locate(lat, lng, at: address.updated_at)
    geolocation.save!
  end
end
```

> Now the S in ECS: a system. This geocoder runs over every address in the
> app, whoever owns it — it never mentions Person or Company.
>
> It only geocodes an address if the owner declares a geolocation in the same
> slot: home with home for a person, the default slot for a company. Any new
> entity type can join in just by declaring the pair.
>
> It stamps each result with the address's updated_at, so an address that
> hasn't changed is skipped, and an edited one is done again.
>
> And I should be honest: the lookup is simulated. Three city centres in a
> hash, where a real app would call a geocoding service.

Rails only finds a new directory under `app` at boot, so restart the console.

<!-- verify:console -->
```ruby
ada = Person.with_marker(:favourite).sole

Geocoder.call                                         # => 2
ada.reload.home_geolocation.coordinates.map(&:to_f)  # => [-31.9523, 115.8613]
Geocoder.call                                         # => 0

ada.update!(home_address_locality: "Auckland", home_address_country: "NZ")
Geocoder.call                                         # => 1
ada.reload.home_geolocation.coordinates.map(&:to_f)  # => [-36.8485, 174.7633]
```

> A new console, so I find Ada again — she's our one favourite. Run the
> geocoder: two addresses, a person's and a company's. Ada is in Perth. Run it
> again: nothing to do, so it does nothing. Now Ada moves to Auckland. Run it:
> one address changed, one redone, and there are her new coordinates.

**Visible result:** `2`, Perth's coordinates, `0`, `1`, Auckland's
coordinates.

## 6. Close — 7:30 to 8:15

**On screen:** back to the terminal.

<!-- verify:commands -->
```sh
ls db/migrate
```

<!-- verify:output -->
```text
20261012023722_ecs_rails_install.rb
```

> Two kinds of entity, ten components, a relationship, a marker, and a system.
> Still one migration.
>
> To be precise about the promise: building from the installed catalogue
> needs no migrations. A new version of the catalogue comes with an upgrade
> migration, and a component of your own — something the catalogue doesn't
> have — gets a table and a migration of its own, like any Rails model.
>
> It isn't free, either. Plain Rails was two to ten times faster in my
> benchmarks, and the blog post has the numbers and the reasons. This is for
> the stage when the shape of your data is still the question.
>
> The tutorial, the gem, the source, a live marketplace built the same way,
> and the blog post are all linked below. Thanks for watching.

End card, held for eight seconds:

- Tutorial — github.com/kranzky/ecs_rails (gem/README.md)
- Gem — rubygems.org/gems/ecs_on_rails
- Live demo and marketplace — ecs-rails.kranzky.com
- Blog post — "The Last Migration" (docs/blog/the-last-migration.md)

**Visible result:** the single migration file, then the end card.

## Video description (for upload)

ECS Rails composes Rails models from reusable components instead of
inheritance. In about eight minutes: install the catalogue and migrate once;
generate a Person and a Company from components; add a relationship and a
marker in Ruby; see which reads and writes composition costs; look at the rows
underneath; and add a geocoder system that works across both entity types —
still with one migration. Geocoding in the video is simulated.

- Tutorial: https://github.com/kranzky/ecs_rails/blob/main/gem/README.md
- Gem: https://rubygems.org/gems/ecs_on_rails
- Source: https://github.com/kranzky/ecs_rails
- Live demo and marketplace: https://ecs-rails.kranzky.com
- Blog post: https://github.com/kranzky/ecs_rails/blob/main/docs/blog/the-last-migration.md
- Every command in this video, runnable: https://github.com/kranzky/ecs_rails/blob/main/docs/video/compose-a-contacts-app.md
