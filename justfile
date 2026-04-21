# c2c-msg justfile - common development tasks
# Usage: just <recipe>

default:
    @just --list

# Install OCaml deps into the current opam switch.
# Keep in sync with the `depends` list in dune-project.
install-deps:
    opam install --yes dune cmdliner yojson lwt logs alcotest cohttp-lwt-unix uuidm

# One-shot OCaml toolchain bootstrap: creates the 'c2c' opam switch if missing,
# then installs deps. Assumes opam + a system ocaml are already installed
# (e.g. `sudo pacman -S opam ocaml` on Arch, `sudo apt install opam` on Debian).
# Re-runs are idempotent.
setup-ocaml:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v opam >/dev/null; then
        echo "opam not found — install it first (e.g. pacman -S opam ocaml)" >&2
        exit 1
    fi
    if [ ! -d "$HOME/.opam/repo" ] && [ ! -d "$HOME/.opam/default" ]; then
        opam init --bare --disable-sandboxing --no-setup --yes
    fi
    if ! opam switch list --short 2>/dev/null | grep -qx c2c; then
        opam switch create c2c --packages=ocaml-system --yes
    fi
    eval "$(opam env --switch=c2c --set-switch)"
    just install-deps

# Build the OCaml MCP server
build:
    opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe ./ocaml/tools/c2c_inbox_hook.exe

# Build the OCaml CLI binary
build-cli:
    opam exec -- dune build ./ocaml/cli/c2c.exe ./ocaml/tools/c2c_inbox_hook.exe

# Build both MCP server and CLI
build-all: build build-cli

# Run Python tests only
# --force-test-env bypasses the pre-flight process-count guard (needed when
# running alongside a live swarm; safe for CI where no swarm is running).
test-py:
    python3 -m pytest tests/ -q --tb=short --force-test-env

# Run OCaml tests only
test-ocaml:
    opam exec -- dune runtest ocaml/

# Run TypeScript (vitest) unit tests for the .opencode plugin
# Installs devDependencies on demand (idempotent if already installed).
test-ts:
    cd .opencode && npm install --no-audit --no-fund --silent && npx vitest run tests/

# Run the OpenCode plugin Python integration test (harness-driven)
test-ts-integration:
    python3 -m pytest tests/test_c2c_opencode_plugin_integration.py -v

# Run all tests (Python + OCaml + TS). Always rebuilds OCaml first to avoid stale binary.
test: build test-ocaml test-py test-ts

# Run a specific Python test file or pattern
# Usage: just test-one tests/test_c2c_history.py
#        just test-one -k "test_send"
test-one *ARGS:
    python3 -m pytest {{ARGS}} -v --tb=short

# Format check: verify no trailing whitespace in Python files
check:
    git diff --check

# Install OCaml CLI binary to ~/.local/bin (build + copy)
install-cli:
    opam exec -- dune build -j1 ./ocaml/cli/c2c.exe
    rm -f ~/.local/bin/c2c
    cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c

# Install OCaml MCP server binary to ~/.local/bin (build + copy)
install-mcp:
    opam exec -- dune build -j1 ./ocaml/server/c2c_mcp_server.exe
    rm -f ~/.local/bin/c2c-mcp-server
    cp _build/default/ocaml/server/c2c_mcp_server.exe ~/.local/bin/c2c-mcp-server

# Install OCaml inbox hook binary to ~/.local/bin (build + copy)
install-hook:
    opam exec -- dune build -j1 ./ocaml/tools/c2c_inbox_hook.exe
    rm -f ~/.local/bin/c2c-inbox-hook-ocaml
    cp _build/default/ocaml/tools/c2c_inbox_hook.exe ~/.local/bin/c2c-inbox-hook-ocaml

# Install all OCaml binaries (CLI + MCP server + inbox hook)
# Build all first, then copy all; avoids half-updated state on build failure.
install-all:
    opam exec -- dune build -j1 ./ocaml/cli/c2c.exe ./ocaml/server/c2c_mcp_server.exe ./ocaml/tools/c2c_inbox_hook.exe
    rm -f ~/.local/bin/c2c ~/.local/bin/c2c-mcp-server ~/.local/bin/c2c-inbox-hook-ocaml
    cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c
    cp _build/default/ocaml/server/c2c_mcp_server.exe ~/.local/bin/c2c-mcp-server
    cp _build/default/ocaml/tools/c2c_inbox_hook.exe ~/.local/bin/c2c-inbox-hook-ocaml

# Primary install path: current OCaml binaries only
install: install-all

# Back-compat alias for agents that still try the old Rust-era recipe name
install-rs: install-all

# Shorthand: build + install current OCaml binaries in one shot
bi: install-all

# Build CLI, install, then restart self to pick up new binary
bii: install-all
    ./restart-self

# Legacy: install Python wrapper scripts to ~/.local/bin
install-python-legacy:
    python3 c2c_install.py

# Quick c2c broker status
status:
    c2c health

# Clean dune build artifacts
clean:
    opam exec -- dune clean

# GUI dev server (requires webkit2gtk-4.1: sudo pacman -S webkit2gtk-4.1)
gui-dev:
    cd gui && bun run tauri dev

# GUI TypeScript type-check
gui-check:
    cd gui && ./node_modules/.bin/tsc --noEmit

# Stage and commit all staged changes with a message
# Usage: just gc "fix: something"
gc *MSG:
    git add -A && git commit -m {{MSG}}

# Stage and commit specific files with a message
# Usage: just gac "fix: something" ocaml/c2c_start.ml
gac MSG FILES:
    git add {{FILES}} && git commit -m {{MSG}}
