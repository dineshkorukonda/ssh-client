# syntax=docker/dockerfile:1
FROM elixir:1.18.2-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix compile --warnings-as-errors && mix release ssh_client

# Keep the build/runtime ABI identical on both supported architectures.
FROM elixir:1.18.2-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 curl ca-certificates && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app /data && chown nobody:nogroup /app /data
WORKDIR /app
COPY --from=builder --chown=nobody:nogroup /app/_build/prod/rel/ssh_client ./
ENV HOME=/data XDG_CONFIG_HOME=/data SSH_CLIENT_PORT=4000 SSH_CLIENT_BIND_IP=0.0.0.0
USER nobody
EXPOSE 4000
HEALTHCHECK --interval=15s --start-period=30s --timeout=3s CMD curl -fsS http://127.0.0.1:4000/health || exit 1
CMD ["/app/bin/ssh_client", "start"]
