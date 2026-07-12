# B160: status-indicator data-path profile

## Scope and environment

This receipt profiles the currently built c2c binary (`0.11.0`, commit
`3f96c4a9`) on Linux `7.0.8-1-cachyos` x86_64 (16 logical CPUs), with Codex
CLI `0.144.1`.  It deliberately measures only local paths: no relay request,
process scan, or archive scan is part of the command.

The benchmark command is reproducible from the checkout after `just build`:

```bash
for command in 'statusline --json' 'instances --json' 'doctor hooks --json'; do
  printf '%s ' "$command"
  for i in $(seq 1 15); do
    start=$(date +%s%N)
    _build/default/ocaml/cli/c2c.exe $command </dev/null >/dev/null 2>/dev/null
    end=$(date +%s%N)
    echo $(( (end-start)/1000000 ))
  done | awk '{s+=$1; if(NR==1||$1<min)min=$1; if($1>max)max=$1} END {printf "n=%d min_ms=%d mean_ms=%.1f max_ms=%d\\n",NR,min,s/NR,max}'
done
```

Measured 2026-07-13 after a normal build, with the OS page cache warm:

| Command | Runs | Min | Mean | Max |
| --- | ---: | ---: | ---: | ---: |
| `statusline --json` | 15 | 28 ms | 38.4 ms | 56 ms |
| `instances --json` | 15 | 161 ms | 183.5 ms | 226 ms |
| `doctor hooks --json` | 15 | 33 ms | 38.5 ms | 50 ms |

A separate 20-run statusline sample was 27 ms minimum, 36.2 ms mean, and 57
ms maximum.  This is a warm-process-start benchmark; a strict cold-cache
benchmark needs root privileges to drop the page cache and was intentionally
not simulated.

## Current path

`c2c statusline` reads the current repository broker's `registry.json`, its
local relay/connector snapshot, and the invoking session's inbox.  It parses a
bounded (64 KiB, 250 ms absolute deadline) stdin JSON payload when supplied.
It does not make network calls, scan processes, scan the archive, or walk all
repository brokers.  Managed Codex launch writes an instance config, mapping,
and a fail-closed delivery-degraded record before its supervisor discovers a
frontend thread; the `instances` figure above bounds the related persisted
state inspection path.

Freshness is intentionally different between the surfaces.  Statusline reads
the current broker at each invocation, so registrations and unread mail are
fresh at process start.  Relay status is a persisted connector observation,
not a live assertion.  The app-server launch record is written atomically by
its single managed launcher; a future shared snapshot would need an explicit
generation, writer ownership, permissions, and stale/degraded marker to avoid
claiming that an old process is live.

## Options considered

| Option | Latency | Correctness and freshness | Cost |
| --- | --- | --- | --- |
| Retain current OCaml reads | 28–56 ms statusline, below the 300 ms client budget | Direct local source of truth; fail-open | Lowest; no extra protocol |
| Supervisor-published snapshot | Could eliminate JSON parsing but not executable startup | Risks stale identity, partial writes, and multi-writer ownership; requires version + atomic replace + mode 0600 + freshness semantics | High operational surface |
| Native helper | Cannot remove the dominant process startup when invoked as a command | Duplicates broker and relay parsing semantics | Highest portability and maintenance cost |

## Recommendation

Retain the OCaml path.  The measured statusline path is already comfortably
inside its budget, and its direct reads preserve the stated no-network and
freshness contracts.  No C/native helper or new snapshot protocol is
recommended.  If a future host embeds c2c in-process or calls it more often
than a statusline refresh, profile that host first; only then consider a
versioned, mode-0600, atomically replaced snapshot with an explicit stale
state.  There is no follow-up implementation bug because the evidence does
not justify one.

## Validation limitation

`dune exec ./ocaml/test/test_c2c_codex_session.exe` could not run in this
environment because the development dependency `yojson` is absent.  `just
build` did compile the production CLI used for the measurements.
