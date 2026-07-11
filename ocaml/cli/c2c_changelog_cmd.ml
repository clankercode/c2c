(* c2c_changelog_cmd — `c2c changelog` subcommand (B126).

   Shows recent changelog entries (embedded in the binary, plus any that a
   background fetch has cached). Instructs where to get more when nothing is
   available locally. See C2c_changelog for the data model + fetch. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax

let github_source_hint =
  Printf.sprintf
    "No changelog entries available locally.\n\
     Get the latest from GitHub:\n\
    \  %s\n\
     (or run `c2c changelog --fetch` to cache it, then re-run `c2c changelog`)."
    C2c_changelog.github_raw_url

let changelog_cmd =
  let since =
    Cmdliner.Arg.(
      value & opt (some string) None
      & info [ "since" ] ~docv:"VERSION"
          ~doc:"Only show entries strictly newer than $(docv) (e.g. --since 0.9.0).")
  in
  let limit =
    Cmdliner.Arg.(
      value & opt int 5
      & info [ "n"; "limit" ] ~docv:"N"
          ~doc:"Show at most $(docv) most-recent entries (default 5). Ignored with --all.")
  in
  let show_all =
    Cmdliner.Arg.(
      value & flag & info [ "all" ] ~doc:"Show all known entries (overrides -n).")
  in
  let fetch =
    Cmdliner.Arg.(
      value & flag
      & info [ "fetch" ]
          ~doc:"Refresh the cached remote changelog from GitHub before printing \
                (best-effort; network-gated).")
  in
  let+ json = json_flag
  and+ since = since
  and+ limit = limit
  and+ show_all = show_all
  and+ fetch = fetch in
  let broker_root = resolve_broker_root () in
  if fetch then begin
    (* Foreground refresh: synchronous (waitpid) so the read below sees the
       fresh cache. Fixture/disable gating handled inside. *)
    if not (C2c_changelog.fetch_remote_sync ~broker_root) then
      Printf.eprintf
        "warning: could not refresh the remote changelog cache (offline?); \
         showing locally-available entries.\n%!"
  end;
  let entries = C2c_changelog.merged_entries ~broker_root in
  let entries =
    match since with
    | Some v -> C2c_changelog.entries_since ~version:v entries
    | None -> entries
  in
  let entries =
    if show_all then entries
    else
      let rec take n = function
        | [] -> []
        | _ when n <= 0 -> []
        | x :: t -> x :: take (n - 1) t
      in
      take (max 0 limit) entries
  in
  if json then
    print_json (`List (List.map C2c_changelog.entry_json entries))
  else if entries = [] then begin
    match since with
    | Some v ->
        Printf.printf "No changelog entries newer than %s.\n" v
    | None ->
        print_string github_source_hint;
        print_newline ()
  end
  else begin
    Printf.printf "%s\n" (C2c_changelog.render_human entries)
  end

let changelog : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "changelog"
       ~doc:"Show recent c2c changelog entries (what's new + setup hints). \
             Entries are embedded in the binary; --fetch refreshes from GitHub. \
             The session-start hook also auto-shows new entries once per client \
             when the binary version changes."
       ~man:
         [ `S "DESCRIPTION"
         ; `P
             "Prints recent changelog entries so agents learn about new c2c \
              features (e.g. the codex hook delivery method, alias suggestions) \
              and can offer to set them up. Newest first."
         ; `P
             "The canonical source is data/changelog/CHANGELOG.md, embedded at \
              build time — no network needed for versions this binary knows. \
              For newer/older entries the binary doesn't embed, a background \
              fetch caches them from GitHub."
         ; `S "EXAMPLES"
         ; `P "c2c changelog            # 5 most recent entries"
         ; `Noblank
         ; `P "c2c changelog --all      # everything"
         ; `Noblank
         ; `P "c2c changelog --since 0.9.0"
         ; `Noblank
         ; `P "c2c changelog --json"
         ])
    changelog_cmd
