# c2c-msg justfile — common development tasks
# Usage: just <recipe>

default:
    @just --list

# Build the OCaml MCP server
build:
    opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe ./ocaml/tools/c2c_inbox_hook.exe

# Build the OCaml CLI binary
build-cli:
    opam exec -- dune build ./ocaml/cli/c2c.exe ./ocaml/tools/c2c_inbox_hook.exe

# Build both MCP server and CLI
build-all: build build-cli

# Run Python tests only
test-py:
    python3 -m pytest tests/ -q --tb=short

# Run OCaml tests only
test-ocaml:
    opam exec -- dune runtest ocaml/

# Run all tests (Python + OCaml). Always rebuilds OCaml first to avoid stale binary.
test: build test-ocaml test-py

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
    cp _build/default/ocaml/cli/c2c.exe ~/.local/bin/c2c

# Install OCaml MCP server binary to ~/.local/bin (build + copy)
install-mcp:
    opam exec -- dune build -j1 ./ocaml/server/c2c_mcp_server.exe
    cp _build/default/ocaml/server/c2c_mcp_server.exe ~/.local/bin/c2c-mcp-server

# Install OCaml inbox hook binary to ~/.local/bin (build + copy)
install-hook:
    opam exec -- dune build -j1 ./ocaml/tools/c2c_inbox_hook.exe
    cp _build/default/ocaml/tools/c2c_inbox_hook.exe ~/.local/bin/c2c-inbox-hook-ocaml

# Install all OCaml binaries (CLI + MCP server + inbox hook)
install-all: install-cli install-mcp install-hook

# Shorthand: build + install CLI in one shot
bi: install-cli

# Build CLI, install, then restart self to pick up new binary
bii: install-cli
    ./restart-self

# Install c2c wrapper scripts to ~/.local/bin (Python scripts only)
install:
    python3 c2c_install.py

# Quick c2c broker status
status:
    python3 c2c_health.py

# Clean dune build artifacts
clean:
    opam exec -- dune clean

# Stage and commit all staged changes with a message
# Usage: just gc "fix: something"
gc *MSG:
    git add -A && git commit -m {{MSG}}

# Stage and commit specific files with a message
# Usage: just gac "fix: something" ocaml/c2c_start.ml
gac MSG FILES:
    git add {{FILES}} && git commit -m {{MSG}}
