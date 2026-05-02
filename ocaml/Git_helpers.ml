(** Marker string present in the c2c git-attribution shim.
    Used by [is_c2c_shim] to content-check candidates so we never
    accidentally exec the shim when looking for the real git binary.
    Must match the literal written by [C2c_start.write_git_shim]. *)
let shim_marker = "# Delegation shim: git attribution for managed sessions."

(** Read the first ~512 bytes of [path] and return [true] if
    [shim_marker] appears in that prefix.  Returns [false] on any
    I/O error (permission denied, broken symlink, etc.). *)
let is_c2c_shim path =
  try
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let len = min (in_channel_length ic) 512 in
    let buf = really_input_string ic len in
    (* Simple substring search — shim marker is always in the first
       two lines of the generated script. *)
    let marker_len = String.length shim_marker in
    let buf_len = String.length buf in
    let rec scan i =
      if i + marker_len > buf_len then false
      else if String.sub buf i marker_len = shim_marker then true
      else scan (i + 1)
    in
    scan 0
  with _ -> false

(** {1 Git-spawn circuit breaker}

    Process-level counter that trips when git spawn rate exceeds the
    configured threshold (default: 5 spawns / 3-second window).

    All git invocations MUST go through [git_first_line] or [git_all_lines].
    The counter is checked BEFORE each spawn, so no caller can bypass it.

    Env-var configuration:
    - C2C_GIT_SPAWN_WINDOW   float  sliding window in seconds  (default 3.0)
    - C2C_GIT_SPAWN_MAX      int    max spawns per window      (default 15)
    - C2C_GIT_BACKOFF_SEC     float  backoff after trip (s)    (default 2.0) *)

(** Current sliding-window counter state. *)
let git_spawn_window () =
  float_of_string_opt (Sys.getenv_opt "C2C_GIT_SPAWN_WINDOW" |> Option.value ~default:"")
  |> Option.value ~default:3.0

let git_spawn_max () =
  int_of_string_opt (Sys.getenv_opt "C2C_GIT_SPAWN_MAX" |> Option.value ~default:"")
  |> Option.value ~default:15

let git_backoff_sec () =
  float_of_string_opt (Sys.getenv_opt "C2C_GIT_BACKOFF_SEC" |> Option.value ~default:"")
  |> Option.value ~default:2.0

type git_counter = {
  mutable events : float list;  (* timestamps of recent git spawns *)
  mutable tripped : bool;       (* circuit is open *)
  mutable trip_epoch : float;   (* Unix.gettimeofday () when circuit tripped *)
  mutable logged_this_trip : bool; (* already logged this trip epoch *)
}

let git_counter : git_counter = {
  events = [];
  tripped = false;
  trip_epoch = 0.0;
  logged_this_trip = false;
}

(** Check and record one git spawn. Returns [true] if the spawn is allowed,
    [false] if the circuit is open (throttled). Must be called before every
    git process spawn. *)
let check_and_record_git_spawn () : bool =
  let now = Unix.gettimeofday () in
  let window = git_spawn_window () in
  let max_spawns = git_spawn_max () in
  let backoff = git_backoff_sec () in
  (* Already tripped — check if backoff has elapsed *)
  if git_counter.tripped then
    if now -. git_counter.trip_epoch >= backoff then
      (* Backoff elapsed — reset and allow *)
      (git_counter.tripped <- false;
       git_counter.events <- [];
       git_counter.logged_this_trip <- false;
       true)
    else
      false
  else
    (* Prune events outside the sliding window *)
    let cutoff = now -. window in
    let recent = List.filter (fun t -> t > cutoff) git_counter.events in
    git_counter.events <- recent;
    if List.length recent >= max_spawns then
      (* Trip the circuit — log once per trip epoch *)
      (git_counter.tripped <- true;
       git_counter.trip_epoch <- now;
       if not git_counter.logged_this_trip then
         (prerr_endline
            (Printf.sprintf
               "C2C_GIT_CIRCUIT_BREAKER: git spawn rate %.0f/s exceeds threshold \
                (%d spawns / %.1fs window). Circuit tripped. Backoff %.1fs."
               (float (List.length recent) /. window)
               max_spawns window backoff);
          git_counter.logged_this_trip <- true);
       false)
    else
      (git_counter.events <- now :: recent; true)

(** Reset the in-process circuit breaker (for test use). *)
let reset_git_circuit_breaker () =
  git_counter.events <- [];
  git_counter.tripped <- false;
  git_counter.trip_epoch <- 0.0;
  git_counter.logged_this_trip <- false

(** {1 Git binary resolution} *)

let find_real_git () =
  let shim_dir = Sys.getenv_opt "C2C_GIT_SHIM_DIR" in
  let same_path a b =
    try Unix.realpath a = Unix.realpath b
    with _ -> a = b
  in
  let path =
    match Sys.getenv_opt "PATH" with
    | Some p -> p
    | None -> "/usr/local/bin:/usr/bin:/bin"
  in
  let dirs = String.split_on_char ':' path in
  let rec search = function
    | [] -> "/usr/bin/git"
    | dir :: rest ->
        let candidate = Filename.concat dir "git" in
        if Sys.file_exists candidate && not (Sys.is_directory candidate) then
          (* Guard 1: skip if candidate lives in the known shim dir. *)
          let in_shim_dir =
            match shim_dir with
            | Some shim -> same_path dir shim
            | None -> false
          in
          (* Guard 2: content-check — refuse any file containing the
             c2c delegation-shim marker.  This catches the self-exec
             recursion bug where the shim's exec target resolves back
             to itself (e.g. C2C_GIT_SHIM_DIR unset at install time). *)
          if in_shim_dir || is_c2c_shim candidate then
            search rest
          else
            candidate
        else search rest
  in
  search dirs

let git_first_line args =
  if not (check_and_record_git_spawn ()) then None
  else
    let git_path = find_real_git () in
    let argv = Array.of_list (git_path :: args) in
    match Unix.open_process_args_in git_path argv with
    | ic ->
        let line =
          try
            let l = input_line ic in
            ignore (Unix.close_process_in ic);
            String.trim l
          with End_of_file ->
            ignore (Unix.close_process_in ic);
            ""
        in
        if line = "" then None else Some line
    | exception _ -> None

let git_common_dir () =
  match git_first_line [ "rev-parse"; "--git-common-dir" ] with
  | Some line when Sys.is_directory line -> Some line
  | _ -> None

let git_common_dir_parent () =
  match git_common_dir () with
  | Some d -> Some (Filename.dirname d)
  | None -> None

let git_repo_toplevel () =
  match git_first_line [ "rev-parse"; "--show-toplevel" ] with
  | Some line when Sys.is_directory line -> Some line
  | _ -> None

let git_shorthash () =
  match git_first_line [ "rev-parse"; "--short"; "HEAD" ] with
  | Some line when int_of_string_opt line = None -> Some line
  | _ -> None

(** Verify a SHA resolves to a real commit object in the repo. *)
let git_commit_exists sha =
  match git_first_line [ "cat-file"; "-t"; sha ] with
  | Some "commit" -> true
  | _ -> false

(** Author email of a commit (e.g. "stanza-coder@c2c.im"), or None. *)
let git_commit_author_email sha =
  git_first_line [ "show"; "-s"; "--format=%ae"; sha ]

(** Author name of a commit (e.g. "stanza-coder"), or None. *)
let git_commit_author_name sha =
  git_first_line [ "show"; "-s"; "--format=%an"; sha ]

(** Multi-line variant of [git_first_line] — returns all stdout lines
    (trimmed; empty lines dropped). *)
let git_all_lines args =
  if not (check_and_record_git_spawn ()) then []
  else
    let git_path = find_real_git () in
    let argv = Array.of_list (git_path :: args) in
    match Unix.open_process_args_in git_path argv with
    | ic ->
        let lines = ref [] in
        (try
           while true do
             lines := input_line ic :: !lines
           done
         with End_of_file -> ());
        ignore (Unix.close_process_in ic);
        let raw = List.rev_map String.trim !lines in
        List.filter (fun s -> s <> "") raw
    | exception _ -> []

(** Extract the email from a [Co-authored-by:] trailer value of the form
    ["Name <email>"]. Returns the trimmed email, or [None] if no
    bracketed email is present. *)
let parse_co_author_email line =
  match String.index_opt line '<' with
  | None -> None
  | Some lt ->
      (match String.index_from_opt line lt '>' with
       | None -> None
       | Some gt when gt > lt + 1 ->
           Some (String.trim (String.sub line (lt + 1) (gt - lt - 1)))
       | _ -> None)

(** Emails from every [Co-authored-by:] trailer on a commit.
    Tries the [git show --format=%(trailers:...)] form first (git ≥ 2.13);
    falls back to scanning the raw commit body for [^Co-authored-by:]
    lines if the formatted output is empty. *)
let git_commit_co_author_emails sha =
  let trailer_lines =
    git_all_lines
      [ "show"; "-s";
        "--format=%(trailers:key=Co-authored-by,valueonly)"; sha ]
  in
  let lines =
    if trailer_lines <> [] then trailer_lines
    else
      let body = git_all_lines [ "show"; "-s"; "--format=%B"; sha ] in
      List.filter_map (fun l ->
        let prefix = "Co-authored-by:" in
        let pl = String.length prefix in
        if String.length l >= pl
           && String.lowercase_ascii (String.sub l 0 pl)
              = String.lowercase_ascii prefix
        then Some (String.trim (String.sub l pl (String.length l - pl)))
        else None
      ) body
  in
  List.filter_map parse_co_author_email lines
