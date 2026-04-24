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
