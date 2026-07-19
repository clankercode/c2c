(* test_c2c_hook_agy — #61: `Stop` is agy's turn end, not its session end.

   [C2c_setup.setup_agy] installs SessionStart + PostToolUse + Stop, so `Stop`
   fires after EVERY turn. It used to share the SessionEnd teardown arm, which
   made a vanilla agy session addressable for its first turn only: turn 1 ends,
   the row is deregistered, and every later send fails to resolve.

   agy has no SessionEnd event to fall back on — agy 1.1.2's hook-args union is
   SessionStart / PreTool / PostTool / PreInvocation / PostInvocation / Stop,
   and its hooks loader has no SessionEnd key. So after this fix nothing tears a
   vanilla agy row down, and the #51 24h activity TTL retires it instead (agy is
   on [Broker.hook_anchor_is_activity_backed] and both PostToolUse and Stop
   refresh its anchor). That is a SOFT hide the next hook fire resurrects, which
   is the correct semantics for a live session — unlike deregistration, which is
   permanent.

   The SessionEnd arm is kept and asserted here so the teardown path stays
   exercisable (hand-fired, or by a future agy that grows the event).

   Every hook fire goes through the real binary under `env -i`, so ambient
   managed markers cannot leak in and silently make a "vanilla" case managed. *)

open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end
  else Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type ctx = { dir : string; home : string; broker_root : string }

let with_ctx f =
  let dir =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-hook-agy-%08x" (Random.bits ())
  in
  let home = dir // "home" and broker_root = dir // "broker" in
  mkdir_p home;
  mkdir_p broker_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { dir; home; broker_root })

(* `env -i` so no ambient C2C_MCP_SESSION_ID / C2C_MCP_AUTO_REGISTER_ALIAS can
   reach [managed_launcher_marker_present] — a leaked marker would suppress the
   "agy-hook" label and make the vanilla cases below vacuously pass. *)
let fire ?(extra_env = []) ctx ~args ~stdin_payload =
  let payload_path = ctx.dir // "payload.json" in
  let out_path = ctx.dir // "cmd.out" in
  let err_path = ctx.dir // "cmd.err" in
  write_file payload_path stdin_payload;
  let extra =
    String.concat " "
      (List.map
         (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s %s %s %s < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      extra
      (Filename.quote c2c_binary)
      args
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

let sid = "019f4fb9-3c7a-7720-96c2-5cacb719d951"

let payload_for event =
  Printf.sprintf
    {|{"hook_event_name":"%s","session_id":"%s","cwd":"/tmp/proj"}|}
    event sid

let rows ctx =
  let registry = ctx.broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    match Yojson.Safe.from_string (read_file registry) with
    | `List rows -> rows
    | `Assoc fields -> (
        match List.assoc_opt "registrations" fields with
        | Some (`List rows) -> rows
        | _ -> [])
    | _ -> []

let field row name =
  match row with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let row_for ctx ~session_id =
  List.find_opt
    (fun row -> field row "session_id" = Some (`String session_id))
    (rows ctx)

let alias_of row =
  match field row "alias" with Some (`String a) -> a | _ -> ""

let anchor_of row =
  match field row "last_activity_ts" with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

(* Register a second peer so addressability can be asserted with a real send —
   `c2c send` refuses a self-send, which would mask an unresolvable recipient. *)
let sender_sid = "peer-sender-sid-0001"
let sender_alias = "agytest-sender-qx41"

let register_sender ctx =
  let rc, _, err =
    fire ctx ~args:(Printf.sprintf "register --alias %s" sender_alias)
      ~stdin_payload:""
      ~extra_env:[ ("C2C_MCP_SESSION_ID", sender_sid) ]
  in
  check int ("sender register exit 0 (stderr: " ^ err ^ ")") 0 rc

let send_to ctx ~alias ~body =
  fire ctx
    ~args:(Printf.sprintf "send %s %s" (Filename.quote alias) (Filename.quote body))
    ~stdin_payload:""
    ~extra_env:[ ("C2C_MCP_SESSION_ID", sender_sid) ]

let session_start ctx =
  let rc, _, _ =
    fire ctx ~args:"hook agy SessionStart" ~stdin_payload:(payload_for "SessionStart")
  in
  check int "SessionStart exit 0" 0 rc;
  match row_for ctx ~session_id:sid with
  | None -> failf "SessionStart did not register a row for %s" sid
  | Some row ->
      check bool "vanilla row is labelled agy-hook" true
        (field row "registered_by" = Some (`String "agy-hook"));
      row

(* THE #61 REGRESSION. A vanilla agy row must survive its turn end and still be
   addressable — the observable symptom was mail to a live agy session failing
   to resolve from turn 2 onwards. *)
let test_stop_keeps_vanilla_row_addressable () =
  with_ctx (fun ctx ->
    register_sender ctx;
    let row = session_start ctx in
    let alias = alias_of row in
    let rc_before, _, _ = send_to ctx ~alias ~body:"turn-1" in
    check int "addressable before Stop" 0 rc_before;
    let rc, _, _ = fire ctx ~args:"hook agy Stop" ~stdin_payload:(payload_for "Stop") in
    check int "Stop exit 0" 0 rc;
    (match row_for ctx ~session_id:sid with
     | None -> fail "Stop deregistered the vanilla agy row (#61)"
     | Some row' ->
         check string "alias unchanged across Stop" alias (alias_of row');
         check bool "still labelled agy-hook after Stop" true
           (field row' "registered_by" = Some (`String "agy-hook")));
    let rc_after, out, err = send_to ctx ~alias ~body:"turn-2" in
    check int
      ("still addressable after Stop (out: " ^ out ^ " err: " ^ err ^ ")")
      0 rc_after)

(* Repeated turn ends must not erode the row either — the real failure mode is
   a long session, not a single Stop. *)
let test_repeated_stops_keep_row () =
  with_ctx (fun ctx ->
    register_sender ctx;
    let alias = alias_of (session_start ctx) in
    for _ = 1 to 3 do
      let rc, _, _ = fire ctx ~args:"hook agy Stop" ~stdin_payload:(payload_for "Stop") in
      check int "Stop exit 0" 0 rc
    done;
    match row_for ctx ~session_id:sid with
    | None -> fail "row gone after 3 turn ends (#61)"
    | Some row' -> check string "alias survives 3 turn ends" alias (alias_of row'))

(* #51 ordering guard: [touch_hook_activity] runs BEFORE the teardown arm, so a
   change to that arm must not cost agy its mid-session anchor. Without a fresh
   anchor the 24h TTL degenerates into measuring session AGE, which is what the
   #51 work exists to prevent — and it is now the ONLY thing retiring agy rows. *)
let test_stop_still_advances_activity_anchor () =
  with_ctx (fun ctx ->
    let before =
      match anchor_of (session_start ctx) with
      | Some ts -> ts
      | None -> fail "SessionStart wrote no last_activity_ts"
    in
    Unix.sleepf 0.05;
    let rc, _, _ = fire ctx ~args:"hook agy Stop" ~stdin_payload:(payload_for "Stop") in
    check int "Stop exit 0" 0 rc;
    match row_for ctx ~session_id:sid with
    | None -> fail "row gone after Stop (#61)"
    | Some row' -> (
        match anchor_of row' with
        | None -> fail "Stop cleared last_activity_ts"
        | Some after ->
            check bool
              (Printf.sprintf "Stop advanced the anchor (%f -> %f)" before after)
              true (after > before)))

(* The teardown path itself still works. Deregistration is PERMANENT, so it must
   stay reachable and must stay narrowly scoped to a genuine session end. *)
let test_session_end_still_deregisters () =
  with_ctx (fun ctx ->
    let alias = alias_of (session_start ctx) in
    let rc, _, _ =
      fire ctx ~args:"hook agy SessionEnd" ~stdin_payload:(payload_for "SessionEnd")
    in
    check int "SessionEnd exit 0" 0 rc;
    check bool ("deregistered on SessionEnd: " ^ alias) true
      (row_for ctx ~session_id:sid = None))

(* #51 blocker 2 must not regress: with a managed launcher marker present the
   row carries NO hook label, so it is invisible to the teardown selector on
   either event. Asserted on both so a future widening of the arm is caught. *)
let test_managed_row_untouched_by_stop_and_session_end () =
  List.iter
    (fun (marker, value) ->
      with_ctx (fun ctx ->
        let managed_env = [ (marker, value) ] in
        let rc, _, _ =
          fire ctx ~args:"hook agy SessionStart"
            ~stdin_payload:(payload_for "SessionStart") ~extra_env:managed_env
        in
        check int "managed SessionStart exit 0" 0 rc;
        (match row_for ctx ~session_id:sid with
         | None -> failf "managed SessionStart registered no row (%s)" marker
         | Some row ->
             check bool ("managed row carries no hook label (" ^ marker ^ ")") true
               (field row "registered_by" = None));
        List.iter
          (fun event ->
            let rc, _, _ =
              fire ctx
                ~args:(Printf.sprintf "hook agy %s" event)
                ~stdin_payload:(payload_for event) ~extra_env:managed_env
            in
            check int (event ^ " exit 0") 0 rc;
            check bool
              (Printf.sprintf "managed row survives %s (%s)" event marker)
              true
              (row_for ctx ~session_id:sid <> None))
          [ "Stop"; "SessionEnd" ]))
    (* C2C_MCP_SESSION_ID doubles as the hook's identity source and takes
       priority over the payload sid, so it must carry the real session id —
       which is what [C2c_start.build_env] exports. The alias marker does not
       feed identity, so that case still resolves the sid from the payload. *)
    [ ("C2C_MCP_SESSION_ID", sid)
    ; ("C2C_MCP_AUTO_REGISTER_ALIAS", "agytest-managed-qx42")
    ]

let () =
  Random.self_init ();
  run "c2c_hook_agy"
    [ ( "hook_agy_turn_end"
      , [ test_case "#61 Stop keeps vanilla row addressable" `Quick
            test_stop_keeps_vanilla_row_addressable
        ; test_case "#61 repeated Stops keep the row" `Quick
            test_repeated_stops_keep_row
        ; test_case "#51 Stop still advances the activity anchor" `Quick
            test_stop_still_advances_activity_anchor
        ; test_case "SessionEnd still deregisters" `Quick
            test_session_end_still_deregisters
        ; test_case "#51 managed row untouched by Stop/SessionEnd" `Quick
            test_managed_row_untouched_by_stop_and_session_end
        ] )
    ]
