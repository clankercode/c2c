---
layout: page
title: "Buildbox validation receipt"
permalink: /reference/buildbox-validation-receipt/
nav_label: "Buildbox receipt"
---

# Buildbox validation receipt

`just bi` accepts an optional buildbox receipt through
`C2C_VALIDATION_RECEIPT=/absolute/path/to/buildbox-pass.json`. The receipt is
checked inside the install lock, after the current checkout has built its
artifacts and immediately before any installed file is removed or copied.
Without that environment variable, the ordinary install path remains
available.

The guard accepts schema version 1 only. Required fields are:

```json
{
  "schema_version": 1,
  "status": "PASS",
  "source": {
    "commit": "40 lowercase hexadecimal characters",
    "tree": "40 lowercase hexadecimal characters"
  },
  "toolchain": "ocamlc version\ndune version\nopam version",
  "dependencies": "output of opam list --installed --short",
  "artifacts": {
    "c2c": "64 lowercase hexadecimal characters",
    "c2c-mcp-server": "64 lowercase hexadecimal characters",
    "c2c-mcp-inner": "64 lowercase hexadecimal characters",
    "c2c-inbox-hook-ocaml": "64 lowercase hexadecimal characters",
    "c2c-stop-hook-ocaml": "64 lowercase hexadecimal characters",
    "c2c-cold-boot-hook": "64 lowercase hexadecimal characters",
    "c2c-post-compact-hook": "64 lowercase hexadecimal characters",
    "c2c-deliver-inbox": "64 lowercase hexadecimal characters"
  }
}
```

`source.commit` is the candidate `HEAD`; `source.tree` is its clean
`git write-tree` result. `toolchain` is the three newline-separated version
outputs in the example, and `dependencies` is the exact installed-package
listing from the buildbox. The artifact names are the installed names and map
to the eight targets in `just install-all`. Evidence fields such as test
commands and exit statuses may be added at the top level, but required fields
cannot be omitted, renamed, or supplied through legacy aliases.

The receipt must describe the same clean source and toolchain that run the
install. A source, dependency, or artifact mismatch refuses before the first
copy; `C2C_INSTALL_FORCE=1` does not bypass a supplied receipt. The guard only
prints field names and mismatch categories, never receipt contents or package
output.
