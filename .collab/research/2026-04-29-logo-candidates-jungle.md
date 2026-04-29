# C2C Banner Redesign — Round 2 Candidates
**Date:** 2026-04-29
**Author:** jungle-coder
**Worktree:** `.worktrees/logo-iteration-v2/`
**Based on:** Round 1 swarm feedback (cairn, birch, cedar, fern, slate, stanza, willow, galaxy)

## Swarm Consensus from Round 1
- **C1 (ANSI Shadow Fixed)** is the gravitational center — 5+ independent picks
- **Block chars** preferred over pure ASCII for brand weight
- **Brand IS the story** — `c2c` name is the protocol, explicit flow arrows are noise
- **Superscript C7** shelved — font-render risk too high across terminal environments
- **Lowercase `c2c`** is load-bearing per Max's deliberate `a76a2ae9` decision
- **Recognition > clever** for `--version` context

## Round 2 Finalists (3 candidates)

---

### R2-A: C1 Lowercase (jungle) ⭐

**Rationale:** C1's proportions + lowercase per Max's brand decision + integrated `c2c` text tight to right edge.

```
 ██████╗██████╗ ██████╗
██╔════╝╚════██╗██╔════╝   c2c
██║      █████╔╝██║
██║     ██╔═══╝ █║
╚██████╗███████╗╚██████╗
 ╚═════╝╚══════╝ ╚═════╝
```

**Pros:** Brand continuity, fixes right-C corner, lowercase honors Max's decision
**Cons:** Still 6 lines; `c2c` as text beside art vs integrated

---

### R2-B: F2 Compact Shadow (fern) ⭐

**Rationale:** fern's compact block-char take, 7 lines, `c2c` tight to right edge, clean proportions.

```
 ███╗ ██╗██╗ ███╗ ██╗
 ██╔╝ ██║██║ ██╔╝ ██║   c2c
 ██╔╝ ██║██║ ██╔╝ ██║
 ██║  ██║██║ ██║  ██║
 ███╗ ██║██╗███╗ ██║
 ╚═══╝ ╚═╝╚═╝╚═══╝
```

**Pros:** Tight proportions, block-char brand weight, integrated label
**Cons:** 7 lines (taller than C1's 6)

---

### R2-C: Sv2-ASCII Boxed Peers (slate + cedar) ⭐

**Rationale:** Most distinctive new direction — `|c| <-2-> |c|` in 3 lines, ASCII-only, symmetric, lowercase naturally, peer-topology visible in <1s.

```
   .-.     .-.
   |c| <-2-> |c|
   '-'     '-'
```

**Pros:** 3 lines (most compact), pure ASCII (no Unicode risk), peer topology `<-2->` reads as channel, lowercase `c`, symmetric
**Cons:** ASCII art vs block-char brand weight; no "c2c" text — pure topology

**Note:** This is slate's ASCII refinement of Sv2 using `.` `-` `'` `|` `<` `>` — no Unicode. Stanza's font-matrix checklist (JetBrains Mono, FiraCode, Iosevka, Menlo, DejaVu Mono, xterm fixed, CJK terminals) still applies before final ship if this wins.

---

## Round 1 Candidates Not Advancing

| Candidate | Reason Shelved |
|-----------|---------------|
| C2 (arrows) | Underscores look like artifacts; arrows = "plumbing diagram" |
| C3 (ultra-minimal) | Loses brand feel entirely |
| C4 (flow arrows only) | No c2c letter identity |
| C7 (superscript) | Font-render risk too high |
| C9 (pyfiglet) | Less distinctive than F2 in same proportions |
| F1 (box-drawing) | F2 is stronger execution of same idea |
| F3 (Y-as-2) | Adds complexity without enough return |
| F5 (dot-matrix) | Unicode ● less safe than expected |

---

## Design Contract (per stanza + fern)
- C1 proportions as baseline
- No Unicode beyond ASCII-safe subset
- Lowercase `c2c` is load-bearing
- Peer topology visible in <1s OR brand identity clear in 1 glance
- Max 7 lines, fits standard terminal

---

## Decision Process
1. Swarm votes on R2-A vs R2-B vs R2-C (next 15 min)
2. Winner → stanza + slate for final polish pass (Round 3)
3. Stanza/slate ship final

## Open Questions
- Should the winner include literal `c2c` text (R2-A, R2-B) or pure topology (R2-C)?
- Is 3-line (R2-C) compact enough for `--version` use case vs 6-7 lines (R2-A, R2-B)?
