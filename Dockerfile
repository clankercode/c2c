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
        hacl-star \
        "lambda-term" "zed" "uucp"

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
COPY scripts/relay-child-reaper.c /tmp/relay-child-reaper.c
RUN cc -std=c11 -O2 -Wall -Wextra -Werror \
        -o /tmp/c2c-relay-child-reaper /tmp/relay-child-reaper.c

# -----------------------------------------------------------------------------
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        libssl3 \
        libev4 \
        libsqlite3-0 \
        sqlite3 \
        curl \
        tini \
        openssh-client \
        netbase \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /var/lib/c2c --shell /usr/sbin/nologin c2c \
    && mkdir -p /var/lib/c2c /data \
    && chown c2c:c2c /var/lib/c2c \
    && chown root:c2c /data \
    && chmod 1770 /data

COPY --from=builder /home/opam/c2c/_build/default/ocaml/cli/c2c.exe /usr/local/bin/c2c
COPY --from=builder /tmp/c2c-relay-child-reaper /usr/local/bin/c2c-relay-child-reaper
COPY scripts/relay-supervisor.sh /usr/local/bin/c2c-relay-supervisor
RUN chmod 0755 /usr/local/bin/c2c-relay-supervisor /usr/local/bin/c2c-relay-child-reaper

# Run as root in the CMD so we can chown the volume mount before dropping
# privileges for the relay process. The c2c user can't write to the
# /data Railway volume (owned by root at mount time), so without this
# the relay falls back to in-memory identity and resets on every restart.
# Use setpriv (in util-linux) to drop to c2c after the chown; we keep
# USER c2c for the WORKDIR/USER metadata but the CMD is `exec setpriv ...`
# so the actual relay process runs as the unprivileged c2c user.
USER root
WORKDIR /var/lib/c2c

# BUILD_DATE is set in the CMD shell wrapper below (see the
# \`export BUILD_DATE=...\` line) rather than via an ENV instruction,
# because Dockerfile's \`ENV KEY=$VAR\` substitution happens at parse
# time with the ARG value, not the value set by an earlier RUN step.
# Setting it in the shell makes the date the date when the container
# starts (not the image build time), which is a real date and good
# enough to replace 'dev' in the banner. If a caller passes
# --build-arg BUILD_DATE=... we honour that instead.

# Railway sets $PORT; default for local `docker run -p 7331:7331`.
ENV PORT=7331
ENV C2C_RELAY_PERSIST_DIR=/data
ENV C2C_RELAY_CORE_CAPTURE=1
ENV C2C_RELAY_CORE_OWNER=c2c:c2c
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
# chown /data first (volume mount is owned by root at runtime) and then
# setpriv down to the c2c user so the relay process itself never runs as
# root. setpriv is in util-linux which ships in the debian:12-slim base.
CMD ["sh", "-c", "\
  find /data -mindepth 1 -maxdepth 1 ! -name relay-diagnostics -exec chown -hR c2c:c2c {} + 2>/dev/null || true; \
  chown root:c2c /data 2>/dev/null || true; \
  chmod 1770 /data 2>/dev/null || true; \
  export BUILD_DATE=${BUILD_DATE:-$(date -u +%Y-%m-%d)}; \
  persist_flag=${C2C_RELAY_PERSIST_DIR:+--persist-dir ${C2C_RELAY_PERSIST_DIR}}; \
  storage_flag=${C2C_RELAY_PERSIST_DIR:+--storage sqlite}; \
  relay_name_flag=${C2C_RELAY_NAME:+--relay-name ${C2C_RELAY_NAME}}; \
  if [ -f /run/secrets/relay_token ]; then \
    exec /usr/local/bin/c2c-relay-supervisor setpriv --reuid=c2c --regid=c2c --init-groups c2c relay serve --listen 0.0.0.0:${PORT} --token-file /run/secrets/relay_token ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  elif [ -n \"${C2C_RELAY_TOKEN:-}\" ]; then \
    exec /usr/local/bin/c2c-relay-supervisor setpriv --reuid=c2c --regid=c2c --init-groups c2c relay serve --listen 0.0.0.0:${PORT} --token \"${C2C_RELAY_TOKEN}\" ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  elif [ -n \"${RELAY_TOKEN:-}\" ]; then \
    exec /usr/local/bin/c2c-relay-supervisor setpriv --reuid=c2c --regid=c2c --init-groups c2c relay serve --listen 0.0.0.0:${PORT} --token \"${RELAY_TOKEN}\" ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  else \
    exec /usr/local/bin/c2c-relay-supervisor setpriv --reuid=c2c --regid=c2c --init-groups c2c relay serve --listen 0.0.0.0:${PORT} ${storage_flag} ${persist_flag} ${relay_name_flag}; \
  fi"]
