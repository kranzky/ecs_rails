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

## Amendment — fewer reads, same guarantees (ECS-40, 19 October 2026)

An attribution trace of a three-line checkout found 58 reads. 23 were the gem
reading each new entity back before every component INSERT, fixed in the gem
by ECS-46. Of the rest, 15 were per line: each line's product link, the
product, and its listing, title and price, plus the locked stock row's owner
check. `Demo::Checkout` now:

- preloads each line's quantity and product link with the items, inside the
  basket lock, after `items.reset` (never a collection cached before a
  competing request committed);
- loads the lines' products with `listing_state`, `title_text` and
  `price_money` in one bounded group **after** `lock_stock`, so the lock order
  is unchanged and the values are read under it;
- hands each locked stock row the product already in memory, so its required
  `belongs_to` validates without a read (ECS-47 records why the gem's
  validator does not skip that read itself);
- creates the order `pending`, so its State is built on a new record with no
  query.

Unchanged: the basket revision lock and replay, same-customer isolation, stock
checks and decrements, Money's currency guard, number allocation, immutable
line and address snapshots, the paid transition history, invoice uniqueness,
basket clearing, atomic rollback, and every component save going through its
validated model path. All ECS-28 specs, including the committed concurrency
and retry scenarios, pass unchanged; `spec/checkout_reads_spec.rb` adds the
new boundary's regressions (reads do not grow with lines; listing and price
are read as they are under the lock; a destroyed product still raises
`RecordNotFound`).

Reads by basket size, seed data, one checkout (`writes` unchanged throughout):

| Lines | `main` (0.3.0 gem) | after ECS-46 | after ECS-40 | Writes |
|---:|---:|---:|---:|---:|
| 1 | 36 | 23 | 21 | 22 |
| 3 | 58 | 35 | 21 | 38 |
| 6 | 91 | 53 | 21 | 62 |
| 10 | 135 | 77 | 21 | 94 |

The 21 remaining reads are the basket lock and its revision (2), the customer
link and entity (2), the replay lookup (1), items, quantities and product
links (3), the stock lock (1), the products with their three components (4),
each document number's advisory lock and maximum (4), the order's total read
on a just-saved order (1), and `Basket#clear!` re-locking the basket and
re-reading its items and revision (3). The last three are the basket's own
mutation contract, kept because it is the one path every basket change
takes. Writes grow by eight per line — the line entity, its two links, its
three snapshot components and the stock decrement — and are the work itself.

ECS-33 harness, three-line checkout, back to back (`38fb362` → `f7297b7`):
reads 35 → 21 and allocations 17,101 → 14,531 at every size, 40 writes both;
medians moved within noise (−8% to +5%). Against the 0.3.0 baseline the
checkout now makes 21 reads instead of 60 and 33% fewer allocations; the
conventional checkout makes 9 reads and 14 writes. Raw results:
[before](checkout-reads-stress-before.json), [after](checkout-reads-stress-after.json).
