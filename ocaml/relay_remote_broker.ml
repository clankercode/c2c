(* relay_remote_broker.ml — SSH-based remote broker polling for relay v1

   Polls a remote broker via SSH, fetches inbox JSON files, caches them
   locally. The relay HTTP server then serves them via GET /remote_inbox/<session_id>.

   v1: one remote broker, 5s polling, SSH using operator's SSH agent. *)

(* Shell-quote a string for use in a shell command.
   Escapes single quotes and wraps in single quotes. *)
let shell_quote s =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' s) ^ "'"

(* Read all content from an in_channel. *)
let rec read_all ic acc =
  try read_all ic (acc ^ input_line ic ^ "\n")
  with End_of_file -> acc

(* ---------------------------------------------------------------------------
 * Configuration
 * --------------------------------------------------------------------------- *)

type remote_broker = {
  id : string;
  ssh_target : string;
  broker_root : string;
}

(* ---------------------------------------------------------------------------
 * SSH: fetch remote inbox
 * --------------------------------------------------------------------------- *)

let fetch_inbox ~(ssh_target : string) ~(broker_root : string)
    ~(session_id : string) : Yojson.Safe.t list =
  let cmd = Printf.sprintf
      "ssh -o StrictHostKeyChecking=no %s 'cat %s/inbox/%s.json 2>/dev/null' 2>/dev/null"
      (shell_quote ssh_target)
      (shell_quote broker_root)
      (shell_quote session_id)
  in
  try
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let raw = String.trim (read_all ic "") in
        if raw = "" then []
        else
          match Yojson.Safe.from_string raw with
          | `List items ->
              List.filter_map (fun item ->
                let str k =
                  match Yojson.Safe.Util.(item |> member k) with
                  | `String s -> s | _ -> ""
                in
                let from_alias = str "from_alias" in
                let _to_alias = str "to_alias" in
                let content = str "content" in
                if from_alias = "" && content = "" then None
                else Some item)
                items
          | _ -> [])
  with _ -> []

let list_remote_sessions ~(ssh_target : string) ~(broker_root : string) : string list =
  let cmd = Printf.sprintf
      "ssh -o StrictHostKeyChecking=no %s 'ls -1 %s/inbox/*.json 2>/dev/null' 2>/dev/null | \
       sed 's|.*/||' | sed 's/\\.json$//'"
      (shell_quote ssh_target)
      (shell_quote broker_root)
  in
  try
    let ic = Unix.open_process_in cmd in
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
      (fun () ->
        let rec loop acc =
          try
            let line = input_line ic in
            let s = String.trim line in
            if s = "" then loop acc else loop (s :: acc)
          with End_of_file -> List.rev acc
        in
        loop [])
  with _ -> []

(* ---------------------------------------------------------------------------
 * In-memory cache
 * --------------------------------------------------------------------------- *)

let cache : (string, Yojson.Safe.t list) Hashtbl.t = Hashtbl.create 16

let get_messages ~(session_id : string) : Yojson.Safe.t list =
  match Hashtbl.find_opt cache session_id with
  | Some msgs -> msgs
  | None -> []

let update_cache ~(session_id : string) (messages : Yojson.Safe.t list) : unit =
  Hashtbl.replace cache session_id messages

(* ---------------------------------------------------------------------------
 * Polling loop
 * --------------------------------------------------------------------------- *)

let poll_once ~(broker : remote_broker) : int =
  let sessions = list_remote_sessions ~ssh_target:broker.ssh_target
      ~broker_root:broker.broker_root in
  let total = ref 0 in
  List.iter (fun session_id ->
    let messages = fetch_inbox ~ssh_target:broker.ssh_target
        ~broker_root:broker.broker_root ~session_id in
    if messages <> [] then begin
      update_cache ~session_id messages;
      total := !total + List.length messages
    end
  ) sessions;
  !total

let start_polling ~(broker : remote_broker)
    ~(interval : float) ~(on_fetch : int -> unit) : (unit -> unit) =
  let stop_flag = ref false in
  let thread = Thread.create (fun () ->
    while not !stop_flag do
      let start_t = Unix.gettimeofday () in
      (try
        let n = poll_once ~broker in
        if n > 0 then on_fetch n
      with _ -> ());
      let elapsed = Unix.gettimeofday () -. start_t in
      let sleep_time = max 0.0 (interval -. elapsed) in
      let rec sleep remaining =
        if !stop_flag || remaining <= 0.0 then ()
        else begin
          let chunk = min 1.0 remaining in
          Thread.delay chunk;
          sleep (remaining -. chunk)
        end
      in
      sleep sleep_time
    done) ()
  in
  let stop () = stop_flag := true; Thread.join thread in
  stop
