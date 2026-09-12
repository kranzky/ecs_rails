# Catalogue upgrade verification (ECS-29)

Upgrade inspects PostgreSQL through ActiveRecord's schema metadata before writing
class files or migrations. The declaration still owns the expected structure.

- Compatible: required columns, defaults, nullability, type parameters, primary
  key, indexes and foreign keys match. Extra application columns/indexes are
  retained. Index names do not matter when their definitions match.
- Additive: missing nullable/defaulted columns, missing indexes and missing
  foreign keys produce ordinary migration statements. Constraints validate
  existing rows when that migration runs; violations fail without deleting or
  rewriting rows. A missing required column without a default needs an explicit
  backfill and is diagnosed instead.
- Incompatible: existing columns have different properties, or an index/FK
  occupying the required columns/name has different semantics. Report actual
  and expected definitions and ask for an explicit reviewed repair followed by
  rerunning upgrade. Never silently alter columns or replace constraints.

Compare the common component columns too: UUID primary key with generated UUID,
non-null entity UUID, slot/default and timestamps. The existing pre-slot migration
is accounted for explicitly, including its prerequisite unique entity_id index,
so generation does not emit the slot or singleton index twice.

Normalize database defaults with registered ActiveRecord types (including JSON
and arrays), without loading application models or their schema caches, and PostgreSQL's default timestamp precision. Normalize only simple
Boolean partial predicates used by the catalogue; arbitrary SQL equivalence is
out of scope and produces a conservative diagnostic. Foreign keys must reference
entities.id with the declared delete action and be validated/nondeferrable.

Verify with real PostgreSQL scratch schemas and legacy rows: run generated
migrations, inspect resulting constraints, preserve existing values and repeat
upgrade against the resulting schema. An incompatible table must never produce
“Every catalogue table is current.”
