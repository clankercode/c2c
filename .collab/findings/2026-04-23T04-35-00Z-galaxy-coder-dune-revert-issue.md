# dune build reverts c2c_mcp.ml working-tree edits

## Symptom
Edits to `ocaml/c2c_mcp.ml` are present in the working tree, build succeeds, tests pass. But after running `dune build`, the file reverts to HEAD — losing all uncommitted edits. The revert happens EVEN AFTER a successful build that confirmed the edits compile.

## How discovered
Attempted to add E2E encryption helpers to Broker module. Successfully built and tested. Then ran `dune build` again (without any git operations in between) and `c2c_mcp.ml` reverted to HEAD.

## Frequency
Every time. Any `dune build` invocation can revert uncommitted `c2c_mcp.ml` changes.

## Severity
Critical — caused 3 consecutive broken commits (d42683e, ddfa290, a7cfce3) that failed to compile. Lost hours to debugging why builds "worked" but commits didn't.

## Root cause
Unknown. The working theory is that `dune` touches the file during build even when the file has no dependencies being rebuilt, possibly as part of cache management or artifact copying.

## WORKAROUND (mandatory for all S3 work)
**Commit IMMEDIATELY after each edit, before running any build or test.**

The correct workflow discovered:
1. Make edit
2. `git add <file>` + `git commit` immediately
3. ONLY THEN run `opam exec -- dune build`
4. If build fails, the commit already has the edit; fix and amend OR make new commit

**DO NOT**: edit → build → discover build works → THEN commit. The commit will have reverted content.

## Additional finding
Even `git checkout HEAD -- ocaml/c2c_mcp.ml` can revert the file. The revert happens at the filesystem level, not git.

## Status
Workaround established. Root cause investigation deferred.
