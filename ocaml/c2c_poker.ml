(* c2c_poker — OCaml wrapper around Python c2c_poker.py fallback *)

let ( // ) = Filename.concat

let resolve_poker_script_path ~(broker_root : string) : string option =
  if broker_root = "" then None
  else
    let p = broker_root // "c2c_poker.py" in
    if Sys.file_exists p then Some p else None

let resolve_terminal ~(pid : int) : (int * string) option =
  None

let start ~(name : string) ~(pid : int) ?(interval : float = 180.0)
    ?(event : string = "heartbeat") ?(sender : string = "c2c-poker")
    ?(alias : string = "") ~(broker_root : string) : int option =
  match resolve_poker_script_path ~broker_root with
  | None -> None
  | Some script ->
      let args =
        [ "python3"; script
        ; "--pid"; string_of_int pid
        ; "--interval"; string_of_float interval
        ; "--event"; event
        ; "--from"; sender
        ]
      in
      try
        let pid_result = Unix.create_process_env "python3"
            (Array.of_list args) (Unix.environment ())
            Unix.stdin Unix.stdout Unix.stderr
        in
        ignore pid_result;
        Some pid_result
      with Unix.Unix_error _ -> None
