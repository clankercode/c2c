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
          match shim_dir with
          | Some shim when same_path dir shim ->
              (* Managed sessions prepend a git shim dir that re-enters `c2c git`.
                 Skip it anywhere we need the real git binary. *)
              search rest
          | _ -> candidate
        else search rest
  in
  search dirs

let git_first_line args =
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
