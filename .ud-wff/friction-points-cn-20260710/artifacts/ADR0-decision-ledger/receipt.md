# ADR0 output receipt

- Worktree: `/home/xertrov/src/c2c/.worktrees/friction-adr0-decision-ledger`
- Tip: `5d7822b7` (single commit). Base `050fd96c` (friction-cn-reconcile tip —
  chain so the B098 decision + reconciliation artifacts are in-tree for link
  validation).
- New `.collab/design/friction-cn-decision-ledger.md`: the authoritative
  settled/deferred/open ledger for rows C036-C046.
  - Settled §1: D1 machine-key identity anchor (Max 2026-07-07, I008 idea file;
    ADR promotion owed), D2 strict B098 (coordinator selection 2026-07-10 on
    operator authority; implemented at H1 tip 68124bdc — honestly noted as NOT
    merged into this branch line), D3 polling-canonical (Max via I004 defer),
    D4 lean v1 schema (J1-J5), D5 trusted-swarm-first posture, D6 I006 split.
  - Deferred §2: I003/I004/I007/I008 + I006 remainder, each with authority and
    explicit reactivation gate; H0 peek-auth explicitly excluded from the I004
    defer.
  - Open gates §3: G1-G11 (relay topology C040, injection responsibility C043,
    message→action audit, alias-release reset C044, broker-vs-relay authority
    C045, delivery guarantee C039, monitor heartbeat, abuse/rate, self-marker
    probe, debug bundle, website IA) — each with question, why-not-inferable,
    required artifact type, and owner. G1/G5 explicitly forbid inferring the
    answer from current accidents.
  - §4 sequencing (C046, "absence of a decision is never permission");
    §5 C036→C046 row-disposition table.
- Cross-links: one pointer line each at the top of
  `.collab/research/friction-cn-reconciliation.md` and
  `.collab/research/friction-cn-b098-decision.md`. No backlog index exists;
  ledger links `.backlog/{ideas,bugs}/*.todo` authority files directly
  (index.yaml machine state untouched).
- Zero protocol/code/behavior change (stated in header, proven by docs-only
  diff).
- Live peer-PASS (independent opus reviewer, not author or its subagent): PASS
  first pass. Evidence IN slice worktree: reviewer's own `just check` rc=0;
  independent link re-validation 12/12; H1 SHA verified + honesty note checked
  against worktree CLAUDE.md state; I004/I008 backlog todo bodies spot-checked;
  four fitness questions (message→action? merged-list default? push delivery?
  who activates I003?) all resolve correctly from the ledger alone. Signed
  artifact `5d7822b7-fable-warden.json` (v2, build_rc=0, all targets).
- Nits: one cosmetic link-text inconsistency (D2); G3 owner cell slightly
  elaborated vs source (faithful).
