# syntax = docker/dockerfile:1
# Production image for the ECS Rails demo bulletin board. Standard Rails 8
# multi-stage build (propshaft assets, PostgreSQL, Thruster in front of Puma).
# Deploy target: Fly.io. See fly.toml.

ARG RUBY_VERSION=3.4.5
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Runtime deps only in the base layer.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# --- build stage: compile gems and assets ---------------------------------
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install gems (the ecs-rails gem is a git source, fetched here).
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .
RUN bundle exec bootsnap precompile app/ lib/

# Precompile assets without the real secret (propshaft).
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# --- final image ----------------------------------------------------------
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run as a non-root user. No `storage` dir — Active Storage was skipped when the
# app was generated (--skip-active-storage), so it does not exist to chown.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Thruster (gzip, static asset serving, X-Sendfile) fronts Puma.
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
