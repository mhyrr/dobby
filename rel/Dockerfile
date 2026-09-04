# The build box, not a runtime. Dobby runs on a plain Linux host as a service
# (design §2.4, docs/box.html); containers were set aside because `bin/dobby
# remote` into the running node is the debugging surface. This file exists so
# the release is assembled on Debian 12 whichever machine asks for it — the
# bundled ERTS is linked against the glibc it was built on, and Debian 12
# (glibc 2.36) is the oldest host the tarball is meant to run on. One file
# builds both architectures: TARGETARCH is whatever `--platform` chose, and on
# a runner of the same architecture nothing is emulated.
#
#     docker build -f rel/Dockerfile --output dist .
#
# leaves dist/dobby-<version>-linux-<arch>.tar.gz and nothing else. Only the
# files rel/Dockerfile.dockerignore lets through reach this build: never .env,
# never the local Home Assistant's storage.

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.4-erlang-28.2-debian-bookworm-20260610-slim

FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /src
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so a change to the house's code does not refetch them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile before the assets: colocated hooks are written into _build at
# compile time and esbuild resolves them from there (mix.exs `assets.build`
# keeps the same order).
RUN mix compile
RUN mix assets.setup && mix assets.deploy

# Last, because runtime.exs and the overlays change without the code changing.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

ARG TARGETARCH
RUN mkdir /out && for tarball in _build/prod/dobby-*.tar.gz; do \
      mv "$tarball" "/out/$(basename "$tarball" .tar.gz)-linux-${TARGETARCH}.tar.gz"; \
    done

# Nothing but the tarball, so `--output` writes exactly one file.
FROM scratch AS tarball
COPY --from=builder /out/ /
