(* c2c_broker_root_check.ml — pure helpers for #352 broker-root migration
   prompts. Kept dependency-free so the unit test (test_c2c_health.ml) can
   pull just this module without dragging in c2c_start / c2c_mcp. *)

let ( // ) = Filename.concat

(** Detect whether a broker root path matches the pre-#294 legacy layout
    (`<git-common-dir>/c2c/mcp`).
    Used by `c2c health` / `c2c doctor` (#352) to surface a migration prompt
    when the resolver is pinned (typically by `C2C_MCP_BROKER_ROOT` or a saved
    instance config) at the legacy path. Substring match — operators may run
    from absolute or symlinked paths and we want to catch both. *)
let is_legacy_broker_root path =
  let p = String.trim path in
  if p = "" then false
  else
    let needle = ".git" // "c2c" // "mcp" in
    let plen = String.length p and nlen = String.length needle in
    let rec loop i =
      if i + nlen > plen then false
      else if String.sub p i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

(** Human-readable warning block emitted by `c2c health` when the resolved
    broker root is on the legacy `.git/c2c/mcp` layout. The migrate command
    became safe to recommend after #360 landed (`99d7b6cf`). *)
let legacy_broker_warning_text root =
  Printf.sprintf
    "\xe2\x9a\xa0 broker root: %s (LEGACY \xe2\x80\x94 migration recommended)\n\
    \  Run: c2c migrate-broker --dry-run     # audit what will move\n\
    \  Then: c2c migrate-broker               # perform migration\n\
    \  Migration is now safe (#360 landed `99d7b6cf`).\n"
    root
