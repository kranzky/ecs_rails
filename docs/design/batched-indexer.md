# Bounded component indexer (ECS-32)

Keep `Demo::Indexer` a component-driven PORO with no concrete entity names.
Select base entities with at least one Text through an SQL subquery and use
ActiveRecord's primary-key batches (default 100 owners). Entity identity is
the batch boundary: component-row batches would split one entity's slots and
overwrite a full document with its last fragment.

Within each batch, check each concrete class's SearchVector declaration once.
Read all Text slots of eligible owners in slot order, and read their existing
default-slot SearchVectors in one query. Reuse those components or build a
virtual one for an eligible owner. Keep the catalogue's `reindex!` behavior,
including its normal validation, persistence and refresh; avoid an alternate
bulk-write path. Group text values only inside this bounded batch.

Preserve eligibility: owners without Text rows are untouched, owners that do
not declare SearchVector are skipped even if they have a stray vector row,
and all persisted Text slots contribute (including undeclared labelled slots).
Nil values remain omitted by SearchVector; ordering is deterministic by slot.
Repeated runs preserve vector identity and yield the same document.

Memory is bounded by the owners and text bytes in a batch, not total dataset
size. One unusually large entity can still require substantial text memory.
The run is not a snapshot: concurrent text changes may be seen by a later
batch, and a subsequent run reconciles changes behind the cursor.

Test small and uneven batch boundaries, many slots on one owner, mixed entity
types, preexisting/missing vectors, repeated runs and owner-query growth.
Measure separate processes on two fixture sizes, recording peak RSS, time and
query categories for the previous and batched implementations. Fixture setup
must occur outside those measured processes in an owned test database.

## Local measurements

2026-09-12, macOS arm64, Ruby 3.4.5, Rails 8.1.3, PostgreSQL 14.15. Each
owner has three text slots; 20% are ineligible groups and the rest are posts
or products with existing default-slot vectors. Each slot repeats four words
80 times. Batch size is 100. Both modes use a fresh Ruby process; fixture
creation is separate. Peak RSS includes Rails boot and the bounded checksum
pass; indexing time and SQL counts cover only the indexer call.

| Owners | Implementation | Owner reads | Total queries | Index seconds | Peak RSS MiB |
| ---: | --- | ---: | ---: | ---: | ---: |
| 250 | Previous | 250 | 851 | 1.231 | 108.1 |
| 250 | Batched | 3 | 409 | 0.671 | 115.5 |
| 2,500 | Previous | 2,500 | 8,501 | 10.141 | 182.8 |
| 2,500 | Batched | 26 | 4,076 | 6.776 | 123.3 |

The extra owner read at 2,500 is the empty final batch probe. Updates and
`reindex!`'s refresh still cost one query each per indexed owner; only discovery
and initial vector/text reads are batched. Document checksums match between
implementations at both sizes. See [raw results](indexer-benchmark-results.json).

These are single local observations, not release performance claims. Small-case
RSS is higher for batching, while the larger case shows much less growth;
allocator state, caches and machine load affect timing and memory peaks. The
bound is per-batch text volume, not a universal byte ceiling or a constant
total number of allocations. Broader comparative measurements belong to ECS-33.

To reproduce from `demo/`, create a dedicated database and migrate it once:

```sh
export RAILS_ENV=test
export DATABASE_URL=postgresql:///ecs_indexer_bench_local
export DEMO_RESET_ENABLED=false
createdb ecs_indexer_bench_local
bin/rails db:migrate

bundle exec ruby script/benchmark_indexer.rb prepare 250
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb baseline
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb batched

bundle exec ruby script/benchmark_indexer.rb prepare 2500
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb baseline
/usr/bin/time -l bundle exec ruby script/benchmark_indexer.rb batched
```

`prepare` replaces only the benchmark fixture; the script refuses non-test
environments and database names outside `ecs_indexer_bench_*`. macOS reports
RSS in bytes; on Linux use `/usr/bin/time -v` and convert its KiB value. The
JSON reports query categories, allocations, elapsed time and output checksum.
