# c2c-msg justfile — common development tasks
# Usage: just <recipe>

default:
    @just --list

# Build the OCaml MCP server
build:
    opam exec -- dune build ./ocaml/server/c2c_mcp_server.exe

# Build the OCaml CLI binary
build-cli:
    opam exec -- dune build ./ocaml/cli/c2c_cli.exe

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

# Install c2c wrapper scripts to ~/.local/bin
install:
    python3 c2c_install.py

# Quick c2c broker status
status:
    python3 c2c_health.py

# Clean dune build artifacts
clean:
    opam exec -- dune clean
