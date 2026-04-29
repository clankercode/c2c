# c2c relay — multi-stage build for Railway / any OCI runtime.
#
# Final image runs: c2c relay serve --listen 0.0.0.0:$PORT ...
# Railway injects $PORT automatically; other platforms should set it.
#
# Stage 1 (builder): OCaml + opam, compile the c2c binary.
# Stage 2 (runtime): debian slim + the binary + tini for signal handling.

ARG OCAML_VERSION=5.2
FROM ocaml/opam:debian-12-ocaml-${OCAML_VERSION} AS builder

# Layer: system build deps (cached unless apt list changes)
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        pkg-config \
        libgmp-dev \
        libssl-dev \
        libev-dev \
        zlib1g-dev \
        libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
USER opam

# Layer: opam deps only — maximizes cache hits across source changes.
# Deps mirror dune-project's (package c2c (depends ...)) list. Listed
# explicitly so this layer caches even before sources land (no
# generate_opam_files / checked-in .opam yet).
WORKDIR /home/opam/c2c
RUN opam update -y \
 && opam install --yes \
        dune cmdliner yojson lwt logs cohttp-lwt-unix uuidm sqlite3 \
        base64 digestif mirage-crypto-ec mirage-crypto-rng \
        mirage-crypto-rng-lwt \
        tls-lwt ca-certs \
        conduit-lwt-unix x509 ptime \
        hacl-star

# Layer: sources + build.
# NOTE: `COPY --chown=...` is silently ignored by the docker legacy
# builder, so on hosts where compose doesn't route through BuildKit
# the source tree ends up root-owned and `dune build` fails with
# `mkdir(_build): Permission denied`. Mirror the explicit chown
# workaround already documented in `Dockerfile.test`. No-op on
# BuildKit hosts (Railway).
COPY dune-project ./
COPY ocaml ./ocaml
USER root
RUN chown -R opam:opam /home/opam/c2c
USER opam
RUN opam exec -- dune build --release ocaml/cli/c2c.exe

# -----------------------------------------------------------------------------
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        libssl3 \
        libev4 \
        libsqlite3-0 \
        sqlite3 \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /var/lib/c2c --shell /usr/sbin/nologin c2c \
    && mkdir -p /var/lib/c2c \
    && chown c2c:c2c /var/lib/c2c

COPY --from=builder /home/opam/c2c/_build/default/ocaml/cli/c2c.exe /usr/local/bin/c2c

USER c2c
WORKDIR /var/lib/c2c

# BUILD_DATE is passed as --build-arg at docker build time so Version.build_date
# shows the actual build date in production. Falls back to "dev" when unset.
ARG BUILD_DATE=dev
ENV BUILD_DATE=$BUILD_DATE

# Railway sets $PORT; default for local `docker run -p 7331:7331`.
ENV PORT=7331
EXPOSE 7331

# tini = PID 1 signal forwarder (so SIGTERM from Railway gets to c2c).
ENTRYPOINT ["/usr/bin/tini", "--"]

# sh -c so $PORT expands at launch. --token-file is picked up from
# /run/secrets/relay_token when Railway mounts a file secret; fall
# back to RELAY_TOKEN env var if only that is set.
# --storage sqlite is required when C2C_RELAY_PERSIST_DIR is set —
# without it, the relay defaults to in-memory mode and dead_letter
# entries are lost on restart (no file persistence).
# --relay-name is set from C2C_RELAY_NAME for cross-host alias validation.
CMD ["sh", "-c", "\
  persist_flag=${C2C_RELAY_PERSIST_DIR:+--persist-dir ${C2C_RELAY_PERSIST_DIR}}; \
  storage_flag=${C2C_RELAY_PERSIST_DIR:+--storage sqlite}; \
  relay_name_flag=${C2C_RELAY_NAME:+--relay-name ${C2C_RELAY_NAME}}; \
  if [ -f /run/secrets/relay_token ]; then \
    exec c2c relay serve --listen 0.0.0.0:${PORT} --token-file /run/secrets/relay_token ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  elif [ -n \"${RELAY_TOKEN:-}\" ]; then \
    exec c2c relay serve --listen 0.0.0.0:${PORT} --token \"${RELAY_TOKEN}\" ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  else \
    exec c2c relay serve --listen 0.0.0.0:${PORT} ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  fi"]
