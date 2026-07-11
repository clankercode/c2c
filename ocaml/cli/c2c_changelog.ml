(* c2c_changelog — agent-facing changelog: parser, per-client version-change
   auto-show state machine, and a fixture-gated background GitHub fetch (B126).

   Canonical source is data/changelog/CHANGELOG.md, embedded into the binary
   as [C2c_changelog_embedded.changelog_md] (see tools/ci/codegen-changelog.py).
   For versions the local binary does not embed, a background fetch fills a
   local cache under <broker_root>/changelog/remote.md.

   Design: .collab/design/2026-07-11T11-42-46Z-B126-changelog.md *)

let ( // ) = Filename.concat

(* One feature within a version. A version section (## v<ver> — <date>) may
   contain several features, each a "### <title>" block with key: value lines. *)
type entry = {
  version : string;              (* e.g. "0.10.0" (leading 'v' stripped) *)
  date : string option;          (* raw date text after the em-dash, if any *)
  title : string;                (* the "### <title>" line *)
  summary : string;              (* 1-3 sentences addressed to the agent *)
  setup : string option;         (* verbatim command to adopt the feature *)
  clients : string list;         (* subset of clients; [] = all clients *)
  audience : string;             (* interactive | autonomous | all (default all) *)
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
           let n = String.length rest and m = String.length sep in
           let rec find i =
             if i + m > n then None
             else if String.sub rest i m = sep then Some i
             else find (i + 1)
           in
           match find 0 with
           | Some i ->
               let ver = String.sub rest 0 i in
               let dt = String.sub rest (i + m) (n - i - m) in
               Some (ver, Some (String.trim dt))
           | None -> None)
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

(* A "### <title>" feature header inside a version section. *)
let parse_feature_header (line : string) : string option =
  let l = String.trim line in
  if String.length l >= 4 && String.sub l 0 4 = "### " then
    Some (String.trim (String.sub l 4 (String.length l - 4)))
  else None

(* Split "key: value" if [key] is one of the known field keys. *)
let known_keys = [ "summary"; "setup"; "clients"; "audience" ]
let parse_kv (line : string) : (string * string) option =
  match String.index_opt line ':' with
  | None -> None
  | Some i ->
      let key = String.trim (String.sub line 0 i) in
      if List.mem key known_keys then
        Some (key, String.trim (String.sub line (i + 1) (String.length line - i - 1)))
      else None

let split_clients (v : string) : string list =
  String.split_on_char ',' v
  |> List.concat_map (String.split_on_char ' ')
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

(* Mutable accumulator for a feature while we scan its lines. *)
type feat_acc = {
  mutable f_summary : string list;  (* reversed *)
  mutable f_setup : string option;
  mutable f_clients : string list;
  mutable f_audience : string;
  mutable f_cur_key : string;       (* which field trailing plain lines extend *)
}

let parse (md : string) : entry list =
  let lines = String.split_on_char '\n' md in
  let out = ref [] in
  let cur_version = ref None in     (* (version, date) *)
  let cur_title = ref None in
  let cur = ref None in             (* feat_acc option *)
  let flush_feature () =
    match !cur_version, !cur_title, !cur with
    | Some (version, date), Some title, Some fa ->
        let summary =
          String.trim (String.concat "\n" (List.rev fa.f_summary))
        in
        out :=
          { version; date; title; summary; setup = fa.f_setup
          ; clients = fa.f_clients; audience = fa.f_audience }
          :: !out
    | _ -> ()
  in
  List.iter
    (fun line ->
       match parse_header line with
       | Some (version, date) ->
           flush_feature ();
           cur_version := Some (version, date);
           cur_title := None;
           cur := None
       | None ->
           (match parse_feature_header line with
            | Some title ->
                flush_feature ();
                cur_title := Some title;
                cur :=
                  Some { f_summary = []; f_setup = None; f_clients = []
                       ; f_audience = "all"; f_cur_key = "summary" }
            | None ->
                (match !cur with
                 | None -> ()  (* prose before any feature — ignored *)
                 | Some fa ->
                     (match parse_kv line with
                      | Some ("summary", v) ->
                          fa.f_summary <- [ v ]; fa.f_cur_key <- "summary"
                      | Some ("setup", v) ->
                          fa.f_setup <- (if v = "" then None else Some v);
                          fa.f_cur_key <- "setup"
                      | Some ("clients", v) ->
                          fa.f_clients <- split_clients v; fa.f_cur_key <- "clients"
                      | Some ("audience", v) ->
                          fa.f_audience <- (if v = "" then "all" else v);
                          fa.f_cur_key <- "audience"
                      | Some _ -> ()
                      | None ->
                          (* continuation line: extend the current field
                             (only summary is multi-line in practice) *)
                          let t = String.trim line in
                          if t <> "" && fa.f_cur_key = "summary" then
                            fa.f_summary <- t :: fa.f_summary))))
    lines;
  flush_feature ();
  List.rev !out

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
  (* stable_sort preserves source order among features sharing a version. *)
  List.stable_sort (fun a b -> compare_version b.version a.version)
    (embedded @ remote_only)

(* Entries strictly newer than [version]. *)
let entries_since ~version (entries : entry list) : entry list =
  List.filter (fun e -> compare_version e.version version > 0) entries

(* Keep entries relevant to [client] ([] clients field = all clients). The
   session-start injection filters to the current client; `c2c changelog`
   shows everything. *)
let filter_client ~client (entries : entry list) : entry list =
  List.filter
    (fun e -> e.clients = [] || List.mem client e.clients)
    entries

(* Keep entries for an [audience] ("all" always matches). *)
let filter_audience ~audience (entries : entry list) : entry list =
  List.filter
    (fun e -> e.audience = "all" || e.audience = audience)
    entries

(* ---- rendering ---------------------------------------------------------- *)

let render_entry_human (e : entry) : string =
  let hdr =
    match e.date with
    | Some d -> Printf.sprintf "v%s — %s — %s" e.version d e.title
    | None -> Printf.sprintf "v%s — %s" e.version e.title
  in
  let buf = Buffer.create 128 in
  Buffer.add_string buf hdr;
  if String.trim e.summary <> "" then begin
    Buffer.add_char buf '\n';
    Buffer.add_string buf e.summary
  end;
  (match e.setup with
   | Some cmd when String.trim cmd <> "" ->
       Buffer.add_string buf (Printf.sprintf "\n  setup: %s" cmd)
   | _ -> ());
  if e.clients <> [] then
    Buffer.add_string buf
      (Printf.sprintf "\n  clients: %s" (String.concat ", " e.clients));
  Buffer.contents buf

let render_human (entries : entry list) : string =
  String.concat "\n\n" (List.map render_entry_human entries)

let entry_json (e : entry) : Yojson.Safe.t =
  `Assoc
    [ ("version", `String e.version)
    ; ("date", match e.date with Some d -> `String d | None -> `Null)
    ; ("title", `String e.title)
    ; ("summary", `String e.summary)
    ; ("setup", match e.setup with Some s -> `String s | None -> `Null)
    ; ("clients", `List (List.map (fun c -> `String c) e.clients))
    ; ("audience", `String e.audience)
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
  let render_one e =
    let setup =
      match e.setup with
      | Some cmd when String.trim cmd <> "" -> Printf.sprintf "\n  offer to run: %s" cmd
      | _ -> ""
    in
    Printf.sprintf "- %s: %s%s" e.title (String.trim e.summary) setup
  in
  Printf.sprintf
    "<c2c-changelog current-version=\"%s\">\n\
     c2c updated — new since you last saw it. You can offer to set up any of these:\n\n\
     %s\n\n\
     Run `c2c changelog` any time to see this again.\n\
     </c2c-changelog>"
    current_version (String.concat "\n" (List.map render_one entries))

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

(* Foreground fetch for the explicit `c2c changelog --fetch` path: same
   fixture/disable gating as the background fetch, but the real network path
   runs curl synchronously (waitpid) so the subsequent read sees the fresh
   cache. Returns true when the cache file exists afterwards. *)
let fetch_remote_sync ~broker_root : bool =
  let dest = remote_cache_path ~broker_root in
  (match Sys.getenv_opt "C2C_CHANGELOG_FETCH_FIXTURE" with
   | Some fixture when String.trim fixture <> "" ->
       spawn_background_fetch ~broker_root  (* fixture path is synchronous *)
   | _ when Sys.getenv_opt "C2C_CHANGELOG_FETCH_DISABLE" = Some "1" -> ()
   | _ ->
       (try
          mkdir_p (broker_changelog_dir ~broker_root);
          let tmp = dest ^ ".sync.tmp" in
          let pid =
            Unix.create_process "curl"
              [| "curl"; "-fsSL"; "--max-time"; "20"; github_raw_url; "-o"; tmp |]
              Unix.stdin Unix.stderr Unix.stderr
          in
          (match Unix.waitpid [] pid with
           | _, Unix.WEXITED 0 -> (try Sys.rename tmp dest with _ -> ())
           | _ -> (try Sys.remove tmp with _ -> ()))
        with _ -> ()));
  Sys.file_exists dest

(* ---- per-client auto-show state machine -------------------------------- *)

(* Multi-process guard for the read-decide-write marker sequence: two hook
   processes racing the same session start could both read the old marker and
   double-inject. Serialise via lockf on a per-client .lock file (same
   pattern as C2c_io.write_file_atomic_locked / broker_log). Degrades to
   unlocked execution if the lock cannot be taken — the marker write itself
   stays atomic; worst case is the pre-lock double-show. *)
let with_marker_lock ~broker_root ~client (f : unit -> 'a) : 'a =
  let lock_path = marker_path ~broker_root ~client ^ ".lock" in
  match
    (try
       mkdir_p (broker_changelog_dir ~broker_root);
       Some (Unix.openfile lock_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600)
     with _ -> None)
  with
  | None -> f ()
  | Some fd ->
      (try Unix.lockf fd Unix.F_LOCK 0 with _ -> ());
      Fun.protect
        ~finally:(fun () ->
          (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
          (try Unix.close fd with _ -> ()))
        f

let read_marker ~broker_root ~client : string option =
  match read_file_opt (marker_path ~broker_root ~client) with
  | Some s -> let s = String.trim s in if s = "" then None else Some s
  | None -> None

let write_marker ~broker_root ~client ~version : unit =
  mkdir_p (broker_changelog_dir ~broker_root);
  ignore (C2c_io.write_file_atomic (marker_path ~broker_root ~client) (version ^ "\n"))

(* Per-client version-change auto-show. Returns [Some block] to inject once, or
   [None]. Marker semantics (parent-specified surfacing contract):
   - marker is per-client and records the last version actually INJECTED;
   - advance it only after a real emit, and only when entries covering
     (marker, current] were locally available;
   - missing entries → emit nothing, trigger a bg fetch, leave marker untouched
     (a later launch shows once the cache lands);
   - no marker at all (fresh install) → set marker to current WITHOUT injecting;
   - downgrade/equal version → no-op, never regress the marker.
   [?current] overrides the binary version (tests). [?audience] filters entries
   for the current run's audience (interactive|autonomous|all). *)
let auto_show ?current ?(audience = "all") ~broker_root ~client ~now () : string option =
  let current = match current with Some v -> v | None -> Version.version in
  with_marker_lock ~broker_root ~client @@ fun () ->
  match read_marker ~broker_root ~client with
  | Some prev when prev = current ->
      None  (* already injected for this version *)
  | None ->
      (* Fresh install: nothing to announce. Record current, warm the cache. *)
      if cache_is_stale ~broker_root ~now () then spawn_background_fetch ~broker_root;
      write_marker ~broker_root ~client ~version:current;
      None
  | Some prev when compare_version current prev <= 0 ->
      None  (* downgrade — never regress the marker *)
  | Some prev ->
      (* Genuine upgrade. Warm the cache (1st-launch "fetch missing"). *)
      if cache_is_stale ~broker_root ~now () then spawn_background_fetch ~broker_root;
      let merged = merged_entries ~broker_root in
      (* Coverage: are the entries up to [current] locally available yet? The
         binary always embeds its own version, so this is true on the common
         upgrade path; the false case is a binary older than the entries it is
         being asked to surface (remote-only) — then we wait for the fetch. *)
      let covered = List.exists (fun e -> e.version = current) merged in
      if not covered then None  (* leave marker; 2nd-launch shows once cached *)
      else begin
        let new_entries =
          entries_since ~version:prev merged
          |> filter_client ~client
          |> filter_audience ~audience
        in
        if new_entries = [] then
          (* Covered, but nothing applies to this client/audience. Per the
             contract, advance only after a real emit — so leave the marker;
             re-eval on the next launch is cheap and idempotent. *)
          None
        else begin
          write_marker ~broker_root ~client ~version:current;
          Some (render_changelog_for_agent ~current_version:current new_entries)
        end
      end
