# ── Build Stage ──────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20240904-slim AS builder

# Install build tools
RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Set build env
ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first (for layer caching)
COPY mix.exs mix.lock ./

# Install dependencies
RUN mix deps.get --only prod && mix deps.compile

# Copy source
COPY config config/
COPY lib lib/

# Compile app and build release
RUN mix compile && mix release

# ── Runtime Stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Copy the release from builder
COPY --from=builder /app/_build/prod/rel/a2a_relay ./

# Cloud Run injects PORT; relay reads it in runtime.exs
ENV PORT=8080
ENV MIX_ENV=prod

EXPOSE 8080

# Run as non-root
RUN useradd --no-create-home --shell /bin/false relay
USER relay

CMD ["/app/bin/a2a_relay", "start"]
