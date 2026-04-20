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
        pkg-config \
        libgmp-dev \
        libssl-dev \
        libev-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
USER opam

# Layer: opam deps only — maximizes cache hits across source changes.
# Deps mirror dune-project's (package c2c (depends ...)) list. Listed
# explicitly so this layer caches even before sources land (no
# generate_opam_files / checked-in .opam yet).
WORKDIR /home/opam/c2c
RUN opam update -y \
 && opam install --yes \
        dune cmdliner yojson lwt logs cohttp-lwt-unix uuidm \
        base64 digestif mirage-crypto-ec mirage-crypto-rng \
        mirage-crypto-rng-unix mirage-crypto-rng-lwt \
        tls-lwt ca-certs

# Layer: sources + build.
COPY --chown=opam:opam dune-project ./
COPY --chown=opam:opam ocaml ./ocaml
RUN opam exec -- dune build --release ocaml/cli/c2c.exe

# -----------------------------------------------------------------------------
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libgmp10 \
        libssl3 \
        libev4 \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /var/lib/c2c --shell /usr/sbin/nologin c2c \
    && mkdir -p /var/lib/c2c \
    && chown c2c:c2c /var/lib/c2c

COPY --from=builder /home/opam/c2c/_build/default/ocaml/cli/c2c.exe /usr/local/bin/c2c

USER c2c
WORKDIR /var/lib/c2c

# Railway sets $PORT; default for local `docker run -p 7331:7331`.
ENV PORT=7331
EXPOSE 7331

# tini = PID 1 signal forwarder (so SIGTERM from Railway gets to c2c).
ENTRYPOINT ["/usr/bin/tini", "--"]

# sh -c so $PORT expands at launch. --token-file is picked up from
# /run/secrets/relay_token when Railway mounts a file secret; fall
# back to RELAY_TOKEN env var if only that is set.
CMD ["sh", "-c", "if [ -f /run/secrets/relay_token ]; then exec c2c relay serve --listen 0.0.0.0:${PORT} --token-file /run/secrets/relay_token; elif [ -n \"${RELAY_TOKEN:-}\" ]; then exec c2c relay serve --listen 0.0.0.0:${PORT} --token \"${RELAY_TOKEN}\"; else exec c2c relay serve --listen 0.0.0.0:${PORT}; fi"]
