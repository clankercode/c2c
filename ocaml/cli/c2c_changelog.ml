(* c2c_changelog — agent-facing changelog: parser, per-client version-change
   auto-show state machine, and a fixture-gated background GitHub fetch (B126).

   Canonical source is data/changelog/CHANGELOG.md, embedded into the binary
   as [C2c_changelog_embedded.changelog_md] (see tools/ci/codegen-changelog.py).
   For versions the local binary does not embed, a background fetch fills a
   local cache under <broker_root>/changelog/remote.md.

   Design: .collab/design/2026-07-11T11-42-46Z-B126-changelog.md *)

let ( // ) = Filename.concat

type entry = {
  version : string;              (* e.g. "0.10.0" (leading 'v' stripped) *)
  date : string option;          (* raw date text after the em-dash, if any *)
  title : string option;         (* first prose line of the section body *)
  body : string list;            (* remaining body lines (bullets + prose) *)
}

(* ---- version parsing / comparison -------------------------------------- *)

(* Numeric-dotted comparison ("0.10.0" > "0.9.0"). Non-numeric components
   fall back to string compare so it never raises. Returns <0, 0, >0. *)
let compare_version (a : string) (b : string) : int =
  let comps s =
    String.split_on_char '.' (String.trim s)
    |> List.map (fun c -> match int_of_string_opt c with Some n -> `N n | None -> `S c)
  in
  let rec go xs ys =
    match xs, ys with
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> 1
    | x :: xt, y :: yt ->
        let c =
          match x, y with
          | `N n, `N m -> compare n m
          | `S p, `S q -> String.compare p q
          | `N _, `S _ -> -1
          | `S _, `N _ -> 1
        in
        if c <> 0 then c else go xt yt
  in
  go (comps a) (comps b)

(* ---- markdown parsing --------------------------------------------------- *)

(* Strip a leading "v"/"V" from a version token. *)
let strip_v s =
  let s = String.trim s in
  if String.length s >= 1 && (s.[0] = 'v' || s.[0] = 'V') then
    String.sub s 1 (String.length s - 1)
  else s

(* Parse a "## v<ver> — <date>" header line into (version, date option).
   Accepts an em-dash (—), en-dash (–) or ascii "-" separator; date optional.
   Returns None if the line is not a version section header. *)
let parse_header (line : string) : (string * string option) option =
  let l = String.trim line in
  if String.length l < 3 || String.sub l 0 3 <> "## " then None
  else begin
    let rest = String.trim (String.sub l 3 (String.length l - 3)) in
    (* Split on the first dash-like separator surrounded by spaces. *)
    let seps = [ " — "; " – "; " - " ] in
    let split_on_sep () =
      List.find_map
        (fun sep ->
           match String.index_opt rest sep.[0] with
           | _ ->
               (* find substring [sep] *)
               let n = String.length rest and m = String.length sep in
               let rec find i =
                 if i + m > n then None
                 else if String.sub rest i m = sep then Some i
                 else find (i + 1)
               in
               (match find 0 with
                | Some i ->
                    let ver = String.sub rest 0 i in
                    let dt = String.sub rest (i + m) (n - i - m) in
                    Some (ver, Some (String.trim dt))
                | None -> None))
        seps
    in
    let ver_tok, date =
      match split_on_sep () with
      | Some (v, d) -> (v, d)
      | None ->
          (* No separator — take the first whitespace-delimited token as version. *)
          (match String.index_opt rest ' ' with
           | Some i -> (String.sub rest 0 i, None)
           | None -> (rest, None))
    in
    let ver = strip_v ver_tok in
    (* Reject non-version headers like "## c2c changelog" — require a digit. *)
    if ver <> "" && String.exists (fun c -> c >= '0' && c <= '9') ver then
      Some (ver, date)
    else None
  end

let parse (md : string) : entry list =
  let lines = String.split_on_char '\n' md in
  (* Fold, accumulating the current section. *)
  let finish cur acc =
    match cur with
    | None -> acc
    | Some (version, date, body_rev) ->
        let body = List.rev body_rev in
        (* trim leading/trailing blank lines *)
        let rec drop = function "" :: t -> drop t | l -> l in
        let body = drop body |> List.rev |> drop |> List.rev in
        let title =
          List.find_opt
            (fun l ->
               let t = String.trim l in
               t <> "" && not (String.length t >= 1 && (t.[0] = '-' || t.[0] = '*')))
            body
          |> Option.map String.trim
        in
        { version; date; title; body } :: acc
  in
  let cur, acc =
    List.fold_left
      (fun (cur, acc) line ->
         match parse_header line with
         | Some (version, date) -> (Some (version, date, []), finish cur acc)
         | None ->
             (match cur with
              | Some (v, d, body) -> (Some (v, d, line :: body), acc)
              | None -> (None, acc)))
      (None, []) lines
  in
  List.rev (finish cur acc)

(* ---- embedded + remote sources ----------------------------------------- *)

let embedded_entries : entry list Lazy.t =
  lazy (parse C2c_changelog_embedded.changelog_md)

let broker_changelog_dir ~broker_root = broker_root // "changelog"
let remote_cache_path ~broker_root = broker_changelog_dir ~broker_root // "remote.md"
let marker_path ~broker_root ~client =
  broker_changelog_dir ~broker_root // Printf.sprintf "last-shown-%s.txt" client

let read_file_opt path =
  try
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (really_input_string ic (in_channel_length ic)))
  with _ -> None

(* Merge embedded ∪ remote-cache, dedup by version (embedded wins), sorted
   newest-first. *)
let merged_entries ~broker_root : entry list =
  let embedded = Lazy.force embedded_entries in
  let remote =
    match read_file_opt (remote_cache_path ~broker_root) with
    | Some md -> (try parse md with _ -> [])
    | None -> []
  in
  let seen = Hashtbl.create 16 in
  List.iter (fun e -> Hashtbl.replace seen e.version ()) embedded;
  let remote_only =
    List.filter (fun e -> not (Hashtbl.mem seen e.version)) remote
  in
  List.sort (fun a b -> compare_version b.version a.version) (embedded @ remote_only)

(* Entries strictly newer than [version]. *)
let entries_since ~version (entries : entry list) : entry list =
  List.filter (fun e -> compare_version e.version version > 0) entries

(* ---- rendering ---------------------------------------------------------- *)

let render_entry_human (e : entry) : string =
  let hdr =
    match e.date with
    | Some d -> Printf.sprintf "v%s — %s" e.version d
    | None -> Printf.sprintf "v%s" e.version
  in
  let body = String.concat "\n" e.body in
  if String.trim body = "" then hdr else hdr ^ "\n" ^ body

let render_human (entries : entry list) : string =
  String.concat "\n\n" (List.map render_entry_human entries)

let entry_json (e : entry) : Yojson.Safe.t =
  `Assoc
    [ ("version", `String e.version)
    ; ("date", match e.date with Some d -> `String d | None -> `Null)
    ; ("title", match e.title with Some t -> `String t | None -> `Null)
    ; ("body", `List (List.map (fun l -> `String l) e.body))
    ]

(* ---- AGENT-FACING SURFACING SEAM (v0 placeholder copy) ------------------

   [render_changelog_for_agent] is the SINGLE seam for the text/markup injected
   into an agent's transcript at session start when the binary version changes.
   The exact phrasing — how entries are worded so the agent knows to OFFER
   setting up new features, the once-only-show wording — is owned by the
   surfacing layer and is intentionally minimal/placeholder here (v0). Rework
   this function's body freely without touching the fetch/cache/state plumbing;
   [auto_show] only depends on its type (entry list -> string). *)
let render_changelog_for_agent ~current_version (entries : entry list) : string =
  Printf.sprintf
    "<c2c-changelog current-version=\"%s\">\n\
     c2c updated — new since you last saw it. You can offer to set up any of these:\n\n\
     %s\n\n\
     Run `c2c changelog` any time to see this again.\n\
     </c2c-changelog>"
    current_version (render_human entries)

(* ---- background fetch (fixture-gated) ---------------------------------- *)

let github_raw_url =
  "https://raw.githubusercontent.com/clankercode/c2c/master/data/changelog/CHANGELOG.md"

let mkdir_p dir = try C2c_mcp.mkdir_p ~mode:0o700 dir with _ -> ()

(* Cache staleness: missing, or older than [ttl_s] seconds. *)
let cache_is_stale ?(ttl_s = 6. *. 3600.) ~broker_root ~now () : bool =
  let path = remote_cache_path ~broker_root in
  match (try Some (Unix.stat path) with _ -> None) with
  | None -> true
  | Some st -> now -. st.Unix.st_mtime > ttl_s

(* Populate the remote cache. Fixture path (C2C_CHANGELOG_FETCH_FIXTURE) copies
   a local file synchronously — deterministic and network-free for tests.
   Otherwise a detached `curl` child is spawned; the parent never waits, so
   session start is never blocked. C2C_CHANGELOG_FETCH_DISABLE=1 short-circuits. *)
let spawn_background_fetch ~broker_root : unit =
  let dir = broker_changelog_dir ~broker_root in
  mkdir_p dir;
  let dest = remote_cache_path ~broker_root in
  match Sys.getenv_opt "C2C_CHANGELOG_FETCH_FIXTURE" with
  | Some fixture when String.trim fixture <> "" ->
      (* Explicit test intent: copy the fixture regardless of DISABLE. *)
        (match read_file_opt fixture with
         | Some contents ->
             let tmp = dest ^ ".tmp" in
             (try
                let oc = open_out_bin tmp in
                output_string oc contents;
                close_out oc;
                Sys.rename tmp dest
          with _ -> ())
       | None -> ())
  | _ when Sys.getenv_opt "C2C_CHANGELOG_FETCH_DISABLE" = Some "1" ->
      ()  (* network disabled (tests / offline) *)
  | _ ->
      (* Detached curl: parent returns immediately (no waitpid → non-blocking).
         Best-effort; failures are silent. *)
      (try
         let tmp = dest ^ ".tmp" in
         let script =
           Printf.sprintf
             "curl -fsSL --max-time 20 %s -o %s 2>/dev/null && mv -f %s %s 2>/dev/null"
             (Filename.quote github_raw_url) (Filename.quote tmp)
             (Filename.quote tmp) (Filename.quote dest)
         in
         let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
         let pid =
           Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; script |]
             devnull devnull devnull
         in
         ignore pid;
         (try Unix.close devnull with _ -> ())
       with _ -> ())

(* ---- per-client auto-show state machine -------------------------------- *)

let read_marker ~broker_root ~client : string option =
  match read_file_opt (marker_path ~broker_root ~client) with
  | Some s -> let s = String.trim s in if s = "" then None else Some s
  | None -> None

let write_marker ~broker_root ~client ~version : unit =
  mkdir_p (broker_changelog_dir ~broker_root);
  ignore (C2c_io.write_file_atomic (marker_path ~broker_root ~client) (version ^ "\n"))

(* Returns [Some block] to show once, or [None]. Persists the per-client marker
   only on terminal outcomes (nothing-to-show / after a successful show), never
   when we are still waiting for entries to become locally available. *)
let auto_show ?current ~broker_root ~client ~now () : string option =
  let current = match current with Some v -> v | None -> Version.version in
  match read_marker ~broker_root ~client with
  | Some prev when prev = current ->
      None  (* already shown for this version *)
  | None ->
      (* First ever run for this client: no update to announce. Record the
         current version and warm the cache for future upgrades. *)
      if cache_is_stale ~broker_root ~now () then spawn_background_fetch ~broker_root;
      write_marker ~broker_root ~client ~version:current;
      None
  | Some prev ->
      (* Version changed. Warm the cache (1st-launch "fetch missing"), then
         show whatever new entries are already available locally. *)
      if cache_is_stale ~broker_root ~now () then spawn_background_fetch ~broker_root;
      let new_entries = entries_since ~version:prev (merged_entries ~broker_root) in
      if new_entries = [] then begin
        (* Nothing available yet. If we've actually regressed (downgrade) or
           there is genuinely nothing newer than [prev] and [prev] >= current,
           advance to avoid a stuck marker; otherwise keep the marker so a
           later launch (post-fetch) can show the entries. *)
        if compare_version prev current >= 0 then
          write_marker ~broker_root ~client ~version:current;
        None
      end
      else begin
        write_marker ~broker_root ~client ~version:current;
        Some (render_changelog_for_agent ~current_version:current new_entries)
      end
