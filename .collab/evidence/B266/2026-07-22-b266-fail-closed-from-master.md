# B266 — fail-closed private reachability migration (clean master base)

**Branch:** `feature/b266-from-master`  
**Base:** `566c175e` (master post-B265)  
**UTC:** 2026-07-21

## Delivered

### SQLite migration (fail-closed)
- `relay_features` table in `sqlite_ddl` + create-time `CREATE IF NOT EXISTS`
- Checked `discovery_visibility` ALTER (raises on failure)
- Require `contact_grants`, `contact_grant_message_ids`, `relay_features` after open
- Idempotent UPSERT markers: `private_reachability=consent_gated`, `contact_protocol=1`
- `schema_version.version=2` stamp with post-insert verify

### Health honesty
- `private_reachability_mode`: InMemory=`process_local`, Sqlite=`consent_gated`
- `/health`: `contact_protocol`, `private_reachability`, `dev_mode`, `production_claims`

### Doctor (`c2c doctor --relay`)
- Pure helpers in `Relay_doctor`: auth_mode, contact_protocol, private_reachability, transport_security
- Wired into `c2c_doctor_relay` check list
- prod+process_local → **Fail**; prod+consent_gated → **Pass**; dev tokenless → **Fail** auth_mode

### CLI lifecycle
- `c2c contact issue|list|revoke|rotate`
- Secrets only via `--secret-out` (0600) or `--show-secret`; default refuses print
- List never prints reusable secrets

## Tests (exit 0)

| Suite | N |
|---|---|
| test_relay_private_migration | 5 |
| test_relay_doctor_private_reachability | 12 |
| test_relay_contact_grants | 36 |
| test_relay_contact_delivery_handlers | 37 |
| test_relay_private_discovery | 24 |

## Residual (documented, not a B266 blocker)
- Pre-B266 binary reopening a migrated DB can ignore markers (M1 ops/deploy control).
