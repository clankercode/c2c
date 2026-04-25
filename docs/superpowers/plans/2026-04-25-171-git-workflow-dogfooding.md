# #171 git-workflow dogfooding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a pre-commit hook via `c2c install git-hook` that blocks direct-to-master commits unless `C2C_COORDINATOR=1`. Also add `c2c doctor --check-rebase-base` for stale-base detection before peer-PASS.

**Architecture:** Hook is a standalone shell script (`.c2c/hooks/pre-commit.sh`) installed into `.git/hooks/pre-commit` via `git rev-parse --git-common-dir` so it works from any worktree. Rebase-base check is a new OCaml command in `c2c doctor`.

---

## File Structure

```
.c2c/hooks/pre-commit.sh           — NEW: hook logic (versioned, shared via git-common-dir)
ocaml/cli/c2c_setup.ml             — MODIFY: add `c2c install git-hook` subcommand
ocaml/cli/c2c_doctor.ml            — MODIFY: add `--check-rebase-base` flag + exit code
```

---

## Task 1: Write pre-commit hook shell script

**Files:**
- Create: `.c2c/hooks/pre-commit.sh`

- [ ] **Step 1: Create hook script**

```sh
#!/usr/bin/env bash
# c2c pre-commit hook — blocks direct-to-master unless C2C_COORDINATOR=1
set -euo pipefail

BRANCH=$(git symbolic-ref HEAD 2>/dev/null | sed 's|refs/heads/||') || true
PROTECTED="^(master|main)$"

if [[ "$BRANCH" =~ $PROTECTED ]] && [[ "${C2C_COORDINATOR:-}" != "1" ]]; then
  echo "[c2c hook] BLOCKED: direct-to-master commit detected." >&2
  echo "Target branch: $BRANCH" >&2
  echo "Set C2C_COORDINATOR=1 to bypass (coordinators only)." >&2
  exit 1
fi

# Bypass: append trailer to commit message file ($1 = commit message file path)
if [[ "${C2C_COORDINATOR:-}" == "1" ]]; then
  MSG_FILE="${1:-}"
  if [[ -n "$MSG_FILE" ]] && [[ -f "$MSG_FILE" ]]; then
    echo "Bypassed-pre-commit-hook: coordinator" >> "$MSG_FILE"
  fi
fi
# Fall through — commit proceeds normally
```

Run:
```bash
chmod +x .c2c/hooks/pre-commit.sh
```

- [ ] **Step 2: Verify hook blocks master without env var**

```bash
git checkout master
C2C_COORDINATOR= git commit --allow-empty -m "test block" 2>&1 || echo "BLOCKED (expected)"
```
Expected: `BLOCKED: direct-to-master commit detected.`

- [ ] **Step 3: Verify hook allows bypass with env var**

```bash
MSG=$(mktemp)
echo "test bypass" > "$MSG"
C2C_COORDINATOR=1 git commit --allow-empty -F "$MSG" 2>&1
rm -f "$MSG"
git log -1 --format="%B"
```
Expected: commit message includes `Bypassed-pre-commit-hook: coordinator`

- [ ] **Step 4: Verify hook allows non-master branches**

```bash
git checkout -b test-hook-branch
C2C_COORDINATOR= git commit --allow-empty -m "test allow" 2>&1
git checkout master
git branch -d test-hook-branch
```
Expected: commit allowed, no hook output

- [ ] **Step 5: Commit hook script**

```bash
git add .c2c/hooks/pre-commit.sh
git commit -m "feat(hooks): add pre-commit hook blocking direct-to-master"
```

---

## Task 2: Add `c2c install git-hook` subcommand

**Files:**
- Modify: `ocaml/cli/c2c_setup.ml`

- [ ] **Step 1: Find `install_all_subcmd` in c2c_setup.ml and add `install_git_hook_subcmd`**

Add after `install_all_subcmd` (around line 1243):

```ocaml
let install_git_hook_subcmd =
  let term =
    let+ dry_run =
      Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ] ~doc:"Show what would be written without writing anything.")
    in
    let output_mode = if dry_run then Json else Human in
    install_git_hook ~output_mode
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "git-hook"
       ~doc:"Install the c2c pre-commit hook that blocks direct-to-master commits.")
    term
```

- [ ] **Step 2: Add `install_git_hook` function**

Add before `install_git_hook_subcmd`:

```ocaml
let install_git_hook ~output_mode =
  let script_dir =
    let repo_root = Git_helpers.git_repo_toplevel () |> Option.value ~default:Filename.current_dir_name in
    Filename.concat repo_root ".c2c" // "hooks" // "pre-commit.sh"
  in
  let hook_dest =
    try
      let git_dir = subprocess_read ["git"; "rev-parse"; "--git-common-dir"] |> String.trim in
      Filename.concat git_dir "hooks" // "pre-commit"
    with _ ->
      Filename.concat (Sys.getcwd ()) ".git" // "hooks" // "pre-commit"
  in
  let hook_content = C2c_hooks.pre_commit_hook in
  if output_mode = Human then
    Printf.printf "Installing c2c pre-commit hook...\n";
    Printf.printf "  source:   %s\n" script_dir;
    Printf.printf "  dest:     %s\n" hook_dest;
    if not (Sys.file_exists (Filename.dirname hook_dest)) then
      Unix.mkdir_p (Filename.dirname hook_dest);
    write_file hook_dest hook_content;
    Unix.chmod hook_dest 0o755;
    Printf.printf "Done.\n"
  else
    let json = `Assoc [
      ("source", `String script_dir);
      ("dest", `String hook_dest);
      ("installed", `Bool true)
    ] in
    print_endline (Yojson.Safe.to_string json)
```

- [ ] **Step 3: Wire `install_git_hook_subcmd` into install command group**

Find the `install_group` definition (around line 1248) and add `install_git_hook_subcmd` to the list of subcommands.

- [ ] **Step 4: Build and verify**

```bash
just build
./c2c.exe install git-hook --dry-run
./c2c.exe install git-hook
```

- [ ] **Step 5: Commit**

```bash
git add ocaml/cli/c2c_setup.ml
git commit -m "feat(setup): add c2c install git-hook subcommand"
```

---

## Task 3: Add `c2c doctor --check-rebase-base`

**Files:**
- Modify: `ocaml/cli/c2c_doctor.ml`

- [ ] **Step 1: Find doctor.ml and locate the main term definition**

Read `ocaml/cli/c2c_doctor.ml` to find where `--json` and other flags are defined.

- [ ] **Step 2: Add `check_rebase_base` flag and logic**

Add a new flag `--check-rebase-base` and handler:

```ocaml
let check_rebase_base () =
  match Git_helpers.git_common_dir () with
  | None ->
      Printf.eprintf "Not in a git repository\n";
      exit 1
  | Some git_dir ->
      let repo_root = Filename.dirname git_dir in
      let master_tip =
        subprocess_read ["git"; "rev-parse"; "origin/master"]
        |> String.trim
      in
      let head_tip =
        subprocess_read ["git"; "rev-parse"; "HEAD"]
        |> String.trim
      in
      let is_ancestor =
        match subprocess_run ["git"; "merge-base"; "--is-ancestor"; master_tip; head_tip] with
        | 0 -> true
        | _ -> false
      in
      if is_ancestor then begin
        Printf.printf "BASE OK\n";
        exit 0
      end else begin
        Printf.printf "STALE — run: git rebase origin/master\n";
        exit 1
      end
```

- [ ] **Step 3: Wire flag into doctor command**

Add `--check-rebase-base` flag to doctor term that calls `check_rebase_base ()`.

- [ ] **Step 4: Build and test**

```bash
just build
./c2c.exe doctor --check-rebase-base
git fetch origin master  # if not up to date
git rebase origin/master  # to test it says STALE when behind
./c2c.exe doctor --check-rebase-base  # should say STALE
```

- [ ] **Step 5: Commit**

```bash
git add ocaml/cli/c2c_doctor.ml
git commit -m "feat(doctor): add --check-rebase-base for stale-base detection"
```

---

## Verification

After all tasks:
- `c2c install git-hook` installs the hook
- `git checkout master && C2C_COORDINATOR= git commit` is blocked
- `C2C_COORDINATOR=1 git commit` bypasses with trailer
- `c2c doctor --check-rebase-base` exits 0 when HEAD is descendant of origin/master, 1 when stale
