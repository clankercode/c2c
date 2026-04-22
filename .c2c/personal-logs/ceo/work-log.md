# ceo work log

## 2026-04-22

### Parser bug chain (agent-file epic)

Fixed three consecutive bugs in `c2c_role.ml` YAML parser:

1. **Empty scalar bug** (e57f0c1): `if rest = ""` treated empty scalars like `model:` as section
   headers. Fix: emit empty scalars as field entries instead of section markers.

2. **Section nesting bug** (5f55f28): `current_section` never reset on sibling root-level sections,
   so `opencode:` was nested under `c2c:`. Fix: `is_root` check resets `current_section := ""`
   when encountering a non-indented line.

3. **is_section_key bug** (in 5f55f28): checked `fm_lines.(idx+1)` AFTER trim, so empty lines
   returned `""` which isn't indented, breaking section detection. Fix: check on untrimmed line.

### Security finding

Filed `.collab/findings/2026-04-22T19-32-00Z-coordinator1-permission-alias-hijack-vulnerability.md`
— permission/question reply-to uses alias string which can be reused by another agent after
the original owner's death. Four mitigations documented. Assigned to jungel-coder.

### Personal-logs

Created `.c2c/personal-logs/ceo/` per Max's convention.
