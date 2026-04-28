(* c2c_git_shim.ml — helpers for the `c2c git` shim.

   Specifically: build the env-array overlay used in the [Unix.execve] call,
   while honouring an operator's pre-set [GIT_AUTHOR_NAME] / [GIT_AUTHOR_EMAIL].

   The shim's intent is "agent commits get correct attribution by default",
   not "agent commits cannot be re-attributed". So we only inject our
   defaults for variables NOT already present in the parent environment.

   See #367 — managed-session git shim must respect CLI-set GIT_AUTHOR_NAME. *)

(* [env_has parent_env key] returns [true] if [key=...] appears in the
   parent environment array. Match is on the [KEY=] prefix. *)
let env_has parent_env key =
  let prefix = key ^ "=" in
  let plen = String.length prefix in
  Array.exists
    (fun s ->
      String.length s >= plen
      && String.sub s 0 plen = prefix)
    parent_env

(* [build_author_overlay ~parent_env ~name ~email] returns the env pairs to
   PREPEND to [parent_env] before exec. We only inject a pair if the parent
   env does not already define it — letting an operator override either or
   both via standard `GIT_AUTHOR_NAME=… c2c git commit …` invocation, or via
   ambient export. *)
let build_author_overlay ~parent_env ~name ~email =
  let acc = [] in
  let acc =
    if env_has parent_env "GIT_AUTHOR_NAME" then acc
    else ("GIT_AUTHOR_NAME=" ^ name) :: acc
  in
  let acc =
    if env_has parent_env "GIT_AUTHOR_EMAIL" then acc
    else ("GIT_AUTHOR_EMAIL=" ^ email) :: acc
  in
  Array.of_list acc
