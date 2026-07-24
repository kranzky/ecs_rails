# Deploying the demo to Fly.io

The demo bulletin board deploys to [Fly.io](https://fly.io) as a single small
always-on machine plus a tiny PostgreSQL. Because the data is disposable (it
resets on a schedule), we use the **cheapest** Postgres option, not managed.

**Rough cost:** ~$4/month (app `shared-cpu-1x` 512 MB ≈ $3.19 + unmanaged
Postgres ≈ $2, minus a little). Drop the app to 256 MB (`fly.toml`) to save ~$1
if it holds up. Neon's free tier is a $0 Postgres alternative — see below.

Everything below is a **one-time setup** and needs your Fly account. `fly.toml`,
the `Dockerfile`, the reset scheduler, and the countdown are already in the repo.

## Prerequisites

- A Fly.io account and `flyctl` installed (`brew install flyctl`), then `fly auth login`.
- Run all commands from `demo/`.

## 1. Create the app

`fly.toml` already exists, so create the app to match (pick a unique name; update
`app = ` in `fly.toml` if you change it):

```sh
fly apps create ecs-rails-demo
```

## 2. Postgres

**Option A — unmanaged Fly Postgres (~$2/mo, all on Fly):**

```sh
fly postgres create --name ecs-rails-demo-db --region syd \
  --vm-size shared-cpu-1x --volume-size 1 --initial-cluster-size 1
fly postgres attach ecs-rails-demo-db --app ecs-rails-demo
```

`attach` sets the `DATABASE_URL` secret automatically.

**Option B — Neon free Postgres ($0):** create a project at neon.tech, then:

```sh
fly secrets set DATABASE_URL="postgres://…neon…/dbname?sslmode=require" --app ecs-rails-demo
```

## 3. Secrets

The app reads its `secret_key_base` from encrypted credentials, so it needs the
master key (kept out of git and the image):

```sh
fly secrets set RAILS_MASTER_KEY="$(cat config/master.key)" --app ecs-rails-demo
```

## 4. Deploy

```sh
fly deploy
```

The `release_command` in `fly.toml` runs `bin/rails db:prepare demo:reset`, so
the database is created, migrated, and seeded on every deploy.

## 5. Custom domain (ecs-rails.kranzky.com)

```sh
fly certs add ecs-rails.kranzky.com --app ecs-rails-demo
fly ips list --app ecs-rails-demo         # note the v4 (A) and v6 (AAAA) addresses
```

Then add DNS records at your provider:

- `A`    `ecs-rails` → the shared IPv4 (or `fly ips allocate-v4` for a dedicated one)
- `AAAA` `ecs-rails` → the IPv6

Fly issues the Let's Encrypt certificate automatically once DNS resolves.
Verify with `fly certs show ecs-rails.kranzky.com`.

## The reset & countdown

- **Interval:** `DEMO_RESET_INTERVAL_MINUTES` in `fly.toml` (default 60). Aligned
  to the wall clock, so resets happen on the boundary (e.g. every hour on the
  hour).
- **How:** `Demo::ResetScheduler` starts a thread when Puma boots (gated on
  `DEMO_RESET_ENABLED=true`), sleeps until the next boundary, and runs
  `Demo::Reset` under a Postgres advisory lock. The UI countdown reads the same
  boundary function, so it stays exactly in sync.
- **Disable:** remove `DEMO_RESET_ENABLED` (or set it to anything but `true`).
- **Manual reset:** `fly ssh console -C "bin/rails demo:reset"`.

## Notes

- The demo depends on the published [`ecs_on_rails`](https://rubygems.org/gems/ecs_on_rails)
  gem from RubyGems (it used a git source before publication). The require path
  and module are still `ecs_rails` / `EcsRails` — only the packaging name
  differs, because every spelling of "ecs rails" is taken on RubyGems.
- Redeploying wipes user-added content (the release command reseeds) — expected
  for a demo.
