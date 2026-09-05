# syntax=docker/dockerfile:1
ARG ELIXIR_VERSION=1.18.2
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20241202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# copy compile configuration
COPY config config

# copy source code
COPY lib lib
COPY priv priv

# compile assets and release
RUN mix compile
RUN mix release ssh_client

# ==============================================================================
# Runner Stage
# ==============================================================================
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl openssh-client \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"
ENV PORT="4000"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/ssh_client ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/ssh_client", "start"]
