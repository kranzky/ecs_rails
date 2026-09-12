# Checkout coordination (ECS-28)

The demo keeps payment simulated and composes only catalogue components. This
is application orchestration, with no new migration or gem lifecycle contract.

## Decisions before implementation

- Lock the basket entity with `with_lock` before reading its items. Every basket
  mutation uses the same lock. Lock the customer while finding/creating their
  singleton basket so simultaneous first additions do not race its unique link.
- A basket carries a Counter in slot `revision`. Edits and successful clearing
  advance it. The checkout form submits that revision; the Order records
  `basket UUID:revision` in an Identifier slot `checkout_request`. Under the
  basket lock, a completed request returns its original order before checking
  the current revision. A changed basket rejects an uncompleted stale form.
  Failed attempts roll back and can retry the same revision. Programmatic
  callers may omit the revision for a fresh attempt, but must supply it to
  recover a successful result after a lost response.
- Lock existing stock Counter rows in ascending product UUID order before
  checking or decrementing any stock. A missing stock row means zero and cannot
  fulfil a positive quantity. Read fresh products and use the locked Counter
  instances, never preloaded stock. Reject nonpositive line quantities.
- Serialize document allocation with PostgreSQL transaction advisory locks,
  one fixed key per number series. Hold the lock from numeric maximum lookup
  through insertion/commit. Require a transaction; no speculative retries or
  rescued uniqueness failures. Numeric maxima continue past six digits.
  Checkout always allocates orders before invoices. This briefly serializes
  successful checkouts; it is appropriate for a small simulated demo. A
  dedicated sequence would scale better but require extra schema; random
  numbers would give up the existing sequential document convention.

The demo uses PostgreSQL's default READ COMMITTED isolation. All document writers
must use Numbering within the insertion transaction; arbitrary Identifier writes
retain only the unique index protection.

The lock order is basket, stock (sorted), order-number series, invoice-number
series. No basket mutation acquires a stock or numbering lock. Ordinary Counter
updates also respect stock row locks. Seller stock forms set an absolute value;
this does not introduce inventory adjustment or stale-form detection for sellers.

The request identifier is scoped to the basket and looked up through its
customer's orders. A replay ignores new payment/address inputs and returns the
immutable result of the completed attempt. Refilled baskets get a new revision.
This demo has no authentication; this mechanism does not add an access policy.

Database rollback restores stock, documents, basket items and revision after a
simulated decline. It cannot undo a real external payment. A real gateway needs
its own idempotency/reconciliation design before network charging is introduced.

## Verification

Use separate checked-out PostgreSQL connections with queues and observed lock
waits, not timing sleeps. Cover two buyers for the last unit, duplicate requests,
independent products contending for numbers, a basket edit during checkout,
declined payment followed by retry, stale forms, and numbering beyond six digits.
