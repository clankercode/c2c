# E2E retest: agy + kimi wake (2026-07-21, post-login)

Host `xsm`. Binary tip ~`4b04893d`. Tmux session `c2ce2e`.

## kimi (managed) — **PASS** (wire-authoritative)

| | |
|---|---|
| Start | `c2c start kimi -n e2e-kimi-wake --model kimi-code/kimi-for-coding-highspeed --new-session` |
| Model shown | **K2.7 Coding Highspeed** (user “k2p7” → full alias `kimi-code/kimi-for-coding-highspeed`) |
| Notifier | `~/.local/share/c2c/kimi-notifiers/e2e-kimi-wake.{pid,sid,log}` live; `delivered 1 message(s)` ×2 |
| Nonces | `WOKE-KM0420`, `WOKE-KM011422` |
| Evidence | `.../session_2eae95ed-.../agents/main/wire.jsonl`: `turn.prompt` → `llm.request` → model text `WOKE-KM0420` / `WOKE-KM011422` |
| Human keystroke to recipient | **none** during wake window |

**Verdict: PASS** — REST inject woke idle managed kimi; model produced nonce.

## agy (managed) — **PASS** (with manual agy-env bootstrap)

| | |
|---|---|
| Start | `c2c start agy -n e2e-agy-wake --new-session -- --model 'Gemini 3.5 Flash (Low)' --dangerously-skip-permissions` |
| Login | OK after ~few s (`max.kaye@gmail.com`, Google AI Pro) |
| Register | Eager managed register **alive** on repo broker (`e2e-agy-wake`) |
| SessionStart → agy-env | **Did not auto-write** — hook never saw `ANTIGRAVITY_LS_ADDRESS` / conversation id |
| Bootstrap | From agy log: HTTP LS `127.0.0.1:35817`, conversation `5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a` after first user turn (“say hi”); wrote `agy-env.json` under `~/.c2c/instances/e2e-agy-wake/` and `~/.local/share/c2c/instances/e2e-agy-wake/` |
| Nonce | `WOKE-AG011646` |
| Evidence | Direct `agy agentapi send-message` + `c2c send e2e-agy-wake ...`; TUI showed model turn and `c2c send ... "WOKE-AG011646"` reply |
| deliver-watch | Running; inbox drained to `[]` after inject |

**Verdict: PASS for agentapi wake once env present.**  
**Residual:** managed start still does not populate `agy-env.json` without external discovery of LS port + conversation UUID (SessionStart hook lacks those env vars on managed path). Follow-up: discover LS from managed agy pid (log line / `/proc` listen ports) + active conversation id, write agy-env from outer/start or deliver-watch.

## Not claimed
- Topology agy→codex / codex→kimi this run
- kill-9 dual-run deliver-service dogfood
- Auto agy-env without manual bootstrap
