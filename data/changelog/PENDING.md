# Pending changelog entries — fold into CHANGELOG.md at the next release

Entries staged here are ready to paste under the next `## vX.Y.Z — <date>`
heading in `data/changelog/CHANGELOG.md` (then delete them from this file).
They must NOT be added to CHANGELOG.md before the release: the embedded
changelog feeds `update_available`, so a version heading newer than
`Version.version` makes every deployed binary print a bogus
"update available" notice (observed 2026-07-13 during B140).

_(empty after 0.12.0 — add new `###` entries below for the next release)_

### Linux release binaries target glibc 2.35 (Ubuntu 22.04+)
summary: Official linux-x64/linux-arm64 release assets are built on Ubuntu
  22.04 and CI-gated so they require at most GLIBC 2.35. They run on Ubuntu
  22.04+ / Debian 12+ / RHEL 9+ with libsqlite3 + libgmp. Ubuntu 20.04 and
  musl still need a local source build. install.sh preflights the host glibc
  floor and verifies the binary before installing.
clients: all
audience: all
