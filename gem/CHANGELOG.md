# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Method delegation (RFC-0005). Component methods and attribute accessors are
  callable on the entity — `user.send_welcome_email`, `user.address = "x"`.
  Name clashes between two components raise `DelegationConflict` at load time;
  `except:`/`only:` are the escape hatch.
- Lazy / virtual components (RFC-0006). `entity.email` always returns an
  `Email`, never `nil` — a missing row yields an in-memory component with every
  attribute at its database default. `entity.save` cascades to the components
  you touched, inserting a row only for those that are dirty, in one
  transaction. Reading a component costs a `SELECT` and nothing else.
- The `component` DSL (RFC-0004). `component Name` on an entity declares what it
  is composed from, generates the reader, and wires the `has_one`.
- `ApplicationComponent` (RFC-0003) and entity subclass resolution — a loaded
  entity comes back as its real subclass (`User`, not `ApplicationEntity`).
- `ApplicationEntity` (RFC-0001) — immutable identity rows in one shared
  `entities` table, discriminated by `model`.
- The component registry (RFC-0002), reload-safe by keying on class name.
- `ecs_rails:install` and `ecs_rails:component` generators (RFC-0008).
- Gem scaffold, MIT licence, and RSpec + PostgreSQL test harness.
