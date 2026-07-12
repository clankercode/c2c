# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

### Deliberate rename-everywhere
summary: You can now change your alias without restarting: an explicit rename atomically updates every identity store — registry, room memberships, relay keys, TOFU pins, allowed_signers, instance config, schedules and memory — and peers see the new name immediately. On failure it rolls back completed work and explicitly reports any incomplete rollback. Implicit renames via register/init stay refused (sticky alias).
setup: c2c rename <new-alias>
audience: autonomous
