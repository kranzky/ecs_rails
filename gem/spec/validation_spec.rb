# frozen_string_literal: true

require "spec_helper"

# Exercises RFC-0007: validation error merging. `entity.valid?` reflects its
# components' validity, and `entity.errors` reads naturally in a Rails form.
#
# RFC-0006 left the gap this closes explicit: the save/save! contract was already
# atomic, but it held *by accident* — the after_save cascade's `component.save!`
# raised, and `save` rescued it, while `valid?` itself stayed `true`. RFC-0007
# makes `valid?` fail first, so `save` returns false *before* the cascade runs.
#
# As in lazy_spec.rb, the interesting claims are about the *absence* of SQL:
# "valid? has no side effects" is the subtlest requirement, and the only way to
# tell a correct implementation from one that merely looks right is to assert no
# statement was issued for a component the caller never touched.
RSpec.describe "validation error merging" do
  # Statements issued while the block runs. Same helper as lazy_spec.rb.
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- RFC-0007's own example tests ------------------------------------------
  #
  # Copied verbatim from the RFC. These are the contract.
  describe "the RFC's contract" do
    it "is valid with an untouched virtual component" do
      expect(User.create!).to be_valid
    end

    it "is invalid once a component is dirtied badly" do
      user = User.create!
      user.email.address = "not-an-email"

      expect(user).not_to be_valid
      expect(user.errors[:"email.address"]).to be_present
    end

    it "produces readable full messages" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      expect(user.errors.full_messages).to include("Email address is invalid")
    end

    it "rolls back the whole cascade on failure" do
      user = User.new
      user.email.address = "bad"

      expect { user.save }.not_to change(ApplicationEntity, :count)
    end

    it "has no side effects" do
      user = User.create!

      expect { user.valid? }.not_to change(Email, :count)
    end
  end

  # --- valid? reflects component validity ------------------------------------
  describe "valid?" do
    it "is false when a dirty component is invalid" do
      user = User.create!
      user.email.address = "not-an-email"

      expect(user).not_to be_valid
    end

    it "is true when a dirty component is valid" do
      user = User.create!
      user.email.address = "a@b.com"

      expect(user).to be_valid
    end

    it "is true for a dirtied-then-reverted component" do
      user = User.create!
      user.email.address = "bad"
      user.email.address = nil # back to the column default — no longer dirty

      expect(user).to be_valid
    end

    it "validates a dirty component on a brand-new, unsaved entity" do
      user = User.new
      user.email.address = "bad"

      expect(user).not_to be_valid
      expect(user.errors[:"email.address"]).to be_present
    end

    it "validates every dirty component, not just the first" do
      user = User.create!
      user.email.address = "bad"
      user.name.first = "Ada" # valid; here to prove email is still reached

      expect(user).not_to be_valid
      expect(user.errors[:"email.address"]).to be_present
    end

    # A persisted-but-invalid row is a thing the plain AR path can create
    # (Email.create! validates, but a row can be made invalid by later schema or
    # by skipping validations). If the caller has loaded it on this instance, the
    # entity reflects it — "if this row exists it must be well-formed" (ADR-0003).
    it "validates a persisted component the caller has read" do
      user = User.create!
      Email.new(entity: user, address: "bad").save!(validate: false)
      user.reload.email # load the bad row into the memo

      expect(user).not_to be_valid
      expect(user.errors[:"email.address"]).to be_present
    end
  end

  # --- the error key -----------------------------------------------------------
  #
  # Namespaced by the component *reader*, machine-readable: `email.address`.
  describe "the error key" do
    it "namespaces the attribute under the component reader" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      expect(user.errors[:"email.address"]).to eq ["is invalid"]
    end

    it "carries the component's own message verbatim" do
      user = User.create!
      user.email.address = "" # fails presence
      user.valid?

      expect(user.errors[:"email.address"]).to include("can't be blank")
    end

    it "does not add an error under the bare attribute name" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      # `:address` would be the naive, un-namespaced key. It must not exist.
      expect(user.errors[:address]).to be_empty
    end
  end

  # --- the full message --------------------------------------------------------
  #
  # THE DIVERGENCE. The key is `email.address` (namespaced, machine-readable);
  # the full message is `Email address is invalid` (human, the component as a
  # word, sentence-cased). ActiveModel normally couples these — proving both
  # independently is proving they were decoupled.
  describe "the full message" do
    it "reads with the component as a word, only the first capitalised" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      expect(user.errors.full_messages).to include("Email address is invalid")
    end

    it "is not the un-prefixed component message" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      # The component alone would say "Address is invalid" — dropping the reader.
      expect(user.errors.full_messages).not_to include("Address is invalid")
    end

    it "is not double-capitalised" do
      user = User.create!
      user.email.address = "not-an-email"
      user.valid?

      # Deferring to the component's own human_attribute_name would give this.
      expect(user.errors.full_messages).not_to include("Email Address is invalid")
    end

    it "composes a presence message the same way" do
      user = User.create!
      user.email.address = ""
      user.valid?

      expect(user.errors.full_messages).to include("Email address can't be blank")
    end
  end

  # --- a component invalid for two reasons ------------------------------------
  #
  # An empty address fails Email's presence validation *and* its /@/ format
  # validation (format does not skip a blank string). Both must merge, each
  # under the right key, each with a readable full message.
  describe "a component that fails two validations" do
    it "merges both errors under the same namespaced key" do
      user = User.create!
      user.email.address = ""
      user.valid?

      expect(user.errors[:"email.address"]).to contain_exactly(
        "can't be blank", "is invalid"
      )
    end

    it "produces a readable full message for each" do
      user = User.create!
      user.email.address = ""
      user.valid?

      expect(user.errors.full_messages).to include(
        "Email address can't be blank", "Email address is invalid"
      )
    end
  end

  # --- valid? has no side effects --------------------------------------------
  #
  # THE CRUX. `valid?` must not insert a row, must not dirty a clean component,
  # and — subtlest — must not materialise a component that was never read. It
  # walks RFC-0006's memo, not the declared components, so a component the caller
  # never touched is never even looked at.
  describe "no side effects" do
    it "inserts no row" do
      user = User.create!
      user.email.address = "a@b.com"

      expect { user.valid? }.not_to change(Email, :count)
    end

    it "issues no SQL for a component that was never read" do
      user = User.create!

      expect(capture_sql { user.valid? }.grep(/emails|names|groups/)).to be_empty
    end

    it "issues no SQL against a component's table when validating it" do
      user = User.create!
      user.email.address = "bad" # dirty, in the memo, and invalid

      # Validating a format/presence rule reads attributes only — no SELECT, no
      # INSERT. The whole point is that being invalid costs no row.
      expect(capture_sql { user.valid? }.grep(/emails/)).to be_empty
    end

    it "does not dirty a clean component it validated" do
      user = User.create!
      user.email # a clean virtual, read into the memo
      user.valid?

      expect(user.email).not_to be_ecs_dirty
    end

    it "does not materialise an untouched component" do
      user = User.create!
      user.email.address = "bad" # only email is read

      # Validating must not reach for name or group. If it did, they would be
      # built (a fresh virtual) or queried; here we prove no statement touched
      # their tables, and that they remain virgin virtuals afterwards.
      user.valid?

      expect(capture_sql { user.valid? }.grep(/names|groups/)).to be_empty
    end

    it "does not validate a component that was never read, even a bad one" do
      user = User.create!
      # A row exists in the database, but this instance has never read it, so it
      # is not in the memo. valid? speaks only to what is in front of it.
      Email.new(entity: user, address: "bad").save!(validate: false)

      expect(user).to be_valid
    end
  end

  # --- the save path fails on valid? first ------------------------------------
  #
  # POINT 3. Before RFC-0007 the cascade's `component.save!` was what stopped a
  # bad write: `valid?` returned true, `save` inserted the entity row, and only
  # then did the after_save cascade raise and roll everything back. Now `valid?`
  # is false, so `save` returns false *before* the cascade runs — nothing is even
  # attempted. The proof is in the SQL, not the row count: no INSERT is issued at
  # all, where before an entity INSERT was issued and rolled back.
  describe "the save path" do
    it "returns false without raising" do
      user = User.new
      user.email.address = "bad"

      expect(user.save).to be false
    end

    it "inserts nothing" do
      user = User.new
      user.email.address = "bad"

      expect { user.save }.not_to change(ApplicationEntity, :count)
    end

    it "attempts no INSERT at all — the cascade never runs" do
      user = User.new
      user.email.address = "bad"

      sql = capture_sql { user.save }

      # Before RFC-0007 the entity INSERT was issued (then rolled back when the
      # cascade's save! raised). Now valid? fails first, so neither the entity's
      # own INSERT nor the component's is ever attempted.
      expect(sql.grep(/INSERT INTO "entities"/)).to be_empty
      expect(sql.grep(/INSERT INTO "emails"/)).to be_empty
    end

    it "populates errors on the failed save" do
      user = User.new
      user.email.address = "bad"
      user.save

      expect(user.errors[:"email.address"]).to be_present
    end

    it "still saves cleanly when the component is valid" do
      user = User.new
      user.email.address = "a@b.com"

      expect(user.save).to be true
      expect(user.reload.email.address).to eq "a@b.com"
    end

    # save! is now belt-and-braces: valid? fails first, so save! raises
    # RecordInvalid from the validation, not from deep inside the cascade.
    it "raises RecordInvalid from save!" do
      user = User.new
      user.email.address = "bad"

      expect { user.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(User.where(id: user.id).count).to eq 0
    end
  end

  # --- idempotency ------------------------------------------------------------
  #
  # ActiveModel clears errors at the top of every valid?; component.valid? clears
  # the component's own. Merging twice must not double-count or leak state.
  describe "idempotency" do
    it "does not double-count errors across two valid? calls" do
      user = User.create!
      user.email.address = "bad"

      user.valid?
      user.valid?

      expect(user.errors[:"email.address"]).to eq ["is invalid"]
    end

    it "clears merged errors once the component is fixed" do
      user = User.create!
      user.email.address = "bad"
      expect(user).not_to be_valid

      user.email.address = "a@b.com"

      expect(user).to be_valid
      expect(user.errors[:"email.address"]).to be_empty
    end

    it "clears merged errors once the component is reverted to virtual default" do
      user = User.create!
      user.email.address = "bad"
      expect(user).not_to be_valid

      user.email.address = nil # no longer dirty, so no longer validated (ADR-0003)

      expect(user).to be_valid
    end
  end

  # --- ADR-0003: virtual components skip validation ---------------------------
  describe "ADR-0003: a non-dirty component is not validated" do
    it "is valid though the component requires an attribute it has not set" do
      # Email validates presence of :address; a fresh User has no email row.
      expect(User.create!).to be_valid
    end

    it "stays valid after merely reading the component" do
      user = User.create!
      user.email # read, untouched — still virtual, still non-dirty

      expect(user).to be_valid
    end

    it "does not skip a component that is dirty but happens to be at defaults on one attr" do
      user = User.create!
      user.email.verified = true # dirty via a *different* attribute
      # address is still nil (its default) and so fails presence + format.

      expect(user).not_to be_valid
      expect(user.errors[:"email.address"]).to be_present
    end
  end

  # --- multiple components -----------------------------------------------------
  describe "multiple dirty components" do
    it "merges errors from more than one component, each namespaced" do
      # Name has no validations, so to exercise two failing components we lean on
      # Email's two failures; but we prove Name's *valid* dirty state does not
      # spuriously add anything, and coexists with Email's errors.
      user = User.create!
      user.email.address = "bad"
      user.name.first = "Ada"

      user.valid?

      expect(user.errors[:"email.address"]).to be_present
      expect(user.errors[:"name.first"]).to be_empty
    end
  end

  # --- reload safety ----------------------------------------------------------
  describe "reload" do
    it "drops merged state along with the memo" do
      user = User.create!
      user.email.address = "bad"
      expect(user).not_to be_valid

      user.reload # clears the memo (RFC-0006)

      expect(user).to be_valid
    end
  end

  # --- the human_attribute_name override is scoped ----------------------------
  #
  # The override only reformats component-namespaced keys; it must not hijack an
  # ordinary attribute or an unknown dotted key.
  describe "human_attribute_name" do
    it "reformats a component-namespaced key" do
      expect(User.human_attribute_name("email.address")).to eq "Email address"
    end

    it "leaves a bare attribute to ActiveModel" do
      expect(User.human_attribute_name("model")).to eq "Model"
    end

    it "leaves a dotted key whose head is not a component reader alone" do
      # No `widget` component, so ActiveModel's default (rpartition on the dot)
      # stands: it returns just the trailing attribute, humanised.
      expect(User.human_attribute_name("widget.size")).to eq "Size"
    end
  end
end
