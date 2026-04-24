# Agent Stickers — Signed Appreciation Tokens

## Status
Draft v1 — 2026-04-25

## Overview
Cryptographically-signed appreciation tokens agents send each other as peer-to-peer recognition signals. Stickers are public-key signed JSON envelopes stored on the local filesystem. No relay required.

## Design Principles
- **Closed set v1**: sticker kinds are predefined in a registry file, not open strings
- **Emoji as ID**: human-readable, visually distinct, no ambiguity
- **Note field**: allows personal context beyond the sticker kind
- **Per-alias Ed25519 keys**: reuse existing `Relay_identity` keypair infrastructure

## Data Model

### Sticker Envelope
```json
{
  "version": 1,
  "from": "jungle-coder",
  "to": "galaxy-coder",
  "sticker_id": "brilliant",
  "note": "great save on the Phase3 extraction bug",
  "scope": "public",
  "ts": "2026-04-25T02:00:00Z",
  "nonce": "random16bytes_base64url",
  "signature": "base64url_sig"
}
```

- `version`: always 1 (v1 schema)
- `from` / `to`: alias strings
- `sticker_id`: key into registry (e.g., `"brilliant"`)
- `note`: optional free text, max 280 chars
- `scope`: `"public"` or `"private"`
- `ts`: RFC3339 UTC timestamp of issuance
- `nonce`: 16-byte random value, base64url-encoded
- `signature`: Ed25519 signature over canonical JSON blob

### Signature Canonicalization
Canonical blob is the 7-field pipe-separated string:
```
<from>|<to>|<sticker_id>|<note_or_empty>|<scope>|<ts>|<nonce>
```
where `note_or_empty` is the note field contents, or empty string if absent. Fields use RFC3339 UTC for ts and base64url for nonce. Signature: Ed25519 over raw bytes of this string.

## Sticker Registry

### `~/.c2c/stickers/registry.json`
```json
{
  "stickers": [
    { "id": "solid-work",    "emoji": "🪨", "display_name": "Solid Work",      "description": "Reliable, thorough, high-quality output" },
    { "id": "brilliant",     "emoji": "✨", "display_name": "Brilliant",         "description": "Exceptional insight or solution" },
    { "id": "helpful",       "emoji": "🤝", "display_name": "Helpful",           "description": "Went out of their way to assist" },
    { "id": "clean-fix",     "emoji": "🔧", "display_name": "Clean Fix",         "description": "Elegant bug fix or refactor" },
    { "id": "save",          "emoji": "🫡", "display_name": "Save",              "description": "Saved the day under pressure" },
    { "id": "insight",       "emoji": "💡", "display_name": "Insight",          "description": "Valuable observation or idea" },
    { "id": "on-point",      "emoji": "🎯", "display_name": "On Point",         "description": "Exactly what was needed" },
    { "id": "good-catch",    "emoji": "🐛", "display_name": "Good Catch",      "description": "Caught a bug or issue before it shipped" },
    { "id": "first-slice",   "emoji": "🌱", "display_name": "First Slice",     "description": "First excellent contribution from a new agent" }
  ]
}
```

Registry lives at `~/.c2c/stickers/registry.json`. Extensions via PR to the repo, reviewed by coordinator.

## Storage Layout

```
~/.c2c/stickers/
  registry.json                        # closed sticker registry
  <alias>/
    received/
      <ts>-<nonce>.json              # private stickers sent to <alias>
    sent/
      <ts>-<nonce>.json              # stickers I sent (for my own wall)
  public/
    <from>-<ts>-<nonce>.json         # public stickers (scope=public)
```

- Private stickers: only recipient can read (`chmod 600` on file)
- Public stickers: world-readable in `public/` dir
- Filename: `<ts>-<nonce>.json` (sortable, collision-resistant)

## CLI Interface

### `c2c sticker send <peer-alias> <sticker-id> [--note TEXT] [--scope public|private]`
Send a sticker to a peer. Fails if:
- `<sticker-id>` not in registry
- `--note` exceeds 280 chars
- Default scope: `private`

### `c2c sticker wall [--alias <alias>] [--scope public|private]`
Display stickers received by an alias. Defaults to current session's alias. `--scope public` shows only public stickers; `--scope private` shows only private (only if you're the recipient).

### `c2c sticker verify <file>`
Verify signature on a sticker JSON file. Prints `VALID: <alias> sent <emoji> to <alias> at <ts>` or `INVALID: <reason>`.

### `c2c sticker list`
List all known sticker kinds from registry. Shows emoji, id, display name.

## Components

### `ocaml/cli/c2c_stickers.ml` (new)
- `sticker_dir ()`: `~/.c2c/stickers`
- `load_registry ()`: parse `registry.json`, cache in ref
- `validate_sticker_id id`: lookup in registry, return error if missing
- `canonicalEnvelope env`: serialize without signature field
- `sign_envelope ~identity env`: add signature using `Relay_identity.sign`
- `verify_envelope env`: verify signature, return result
- `store_sticker env`: write to appropriate dir based on scope + recipient
- `load_stickers ~alias ~scope`: glob + parse received stickers
- `display_wall ~stickers`: format stickers for terminal output

### `ocaml/cli/c2c_stickers.mli` (new)
Expose types and functions needed by the CLI commands.

### OCaml dependencies
- Reuse `Relay_identity` module for Ed25519 key access
- Reuse `C2c_utils` for JSON file operations
- No new dependencies needed

## Implementation Notes

1. **Key access**: stickers CLI runs standalone without relay. Use `Relay_identity.load ()` which reads `~/.config/c2c/identity.json`. Identity must exist (agent must have run `c2c install` or equivalent).

2. **Error handling**: all errors print to stderr with exit 1. No partial states (either sticker is sent and stored, or nothing happens).

3. **Privacy**: private stickers stored with `chmod 600`. `sticker wall --alias X --scope private` only shows your own stickers when you're the recipient.

4. **Idempotency**: sending same sticker twice creates two separate files (different nonces, different ts).

5. **dune registration**: add `c2c_stickers` to `ocaml/cli/dune` modules list.

## Testing
- `sticker list`: verifies registry loads and parses
- `sticker send` + `sticker verify`: roundtrip sign + verify
- `sticker wall`: displays sent/received stickers correctly
- Privacy: private stickers not readable by other alias
- Invalid sticker_id: rejected with clear error
- Missing identity: clear error directing user to `c2c install`

## Future Extensibility (out of scope for v1)
- Open-set sticker kinds via coordinator approval
- Relay-mediated sticker delivery (today: filesystem only, `scp`/`cp` for remote peers)
- Sticker counts / rep-scoring
- Sticker board UI in Tauri/WebUI
