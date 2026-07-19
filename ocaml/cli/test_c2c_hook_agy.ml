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

let rows_at broker_root =
  let registry = broker_root // "registry.json" in
  if not (Sys.file_exists registry) then []
  else
    match Yojson.Safe.from_string (read_file registry) with
    | `List rows -> rows
    | `Assoc fields -> (
        match List.assoc_opt "registrations" fields with
        | Some (`List rows) -> rows
        | _ -> [])
    | _ -> []

let rows ctx = rows_at ctx.broker_root

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

(* ------------------------------------------------------------------ *)
(* #69: which BROKER a vanilla agy session lands in.

   agy runs each hook command with cwd set to the directory containing
   hooks.json — `~/.gemini/config` (documented in agy's own embedded hook
   reference, and confirmed by a live 1.1.4 probe: every fire recorded
   cwd=/home/xertrov/.gemini/config). That directory is not a git repo, so
   [resolve_broker_root ()] fingerprints it as "default" and a vanilla agy
   session registers into `~/.c2c/repos/default/broker` — invisible to peers
   in the repo it is actually working in. Managed agy escaped this only
   because `c2c start` exports C2C_MCP_BROKER_ROOT, which hook children
   inherit.

   The workspace IS recoverable from the payload. agy's common input fields
   include `workspacePaths`, and a live probe on 1.1.4 found it populated with
   the real workspace root on EVERY event of an interactive session, and of
   `agy -p --add-dir <ws>`. #69/#68 recorded it as always `[]`; that came from
   plain `agy --print`, which registers no workspace at all — the field was
   honestly reporting "no workspace", not failing to report one.

   These cases deliberately do NOT set C2C_MCP_BROKER_ROOT. Setting it is both
   what masks this bug and what fixes it, which is exactly why #65's live
   verification (correctly isolated via that env var) could not see #69. They
   therefore use [fire_vanilla], which pins only HOME and runs the hook from a
   NON-repo cwd, reproducing agy's real invocation. *)

let fire_vanilla ?(extra_env = []) ctx ~hook_cwd ~args ~stdin_payload =
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
    Printf.sprintf "cd %s && env -i HOME=%s PATH=%s %s %s %s < %s > %s 2> %s"
      (Filename.quote hook_cwd)
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      extra
      (Filename.quote c2c_binary)
      args
      (Filename.quote payload_path)
      (Filename.quote out_path)
      (Filename.quote err_path)
  in
  let rc = Sys.command cmd in
  (rc, read_file out_path, read_file err_path)

(* A real git repo with a unique remote, so its fingerprint is deterministic,
   unique per test, and — crucially — NOT "default". *)
let make_workspace ctx ~name =
  let ws = ctx.dir // name in
  mkdir_p ws;
  let quiet = " >/dev/null 2>&1" in
  ignore (Sys.command (Printf.sprintf "git -C %s init -q%s" (Filename.quote ws) quiet));
  ignore
    (Sys.command
       (Printf.sprintf "git -C %s remote add origin https://example.invalid/%s-%08x.git%s"
          (Filename.quote ws) name (Random.bits ()) quiet));
  ws

(* agy's hook cwd stand-in: a plain directory, not a repo — the property that
   makes [resolve_broker_root ()] fall through to the "default" fingerprint. *)
let make_hook_cwd ctx =
  let d = ctx.dir // "gemini-config" in
  mkdir_p d;
  d

let repos_dir ctx = ctx.home // ".c2c" // "repos"

(* Every repo fingerprint under HOME whose broker registered [session_id].
   Asserting over the whole set (rather than probing one expected path) is
   what makes "landed in `default`" a visible failure instead of a silent
   absence, and catches a row written to two brokers at once. *)
let fingerprints_holding ctx ~session_id =
  let dir = repos_dir ctx in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.filter (fun fp ->
           List.exists
             (fun row -> field row "session_id" = Some (`String session_id))
             (rows_at (dir // fp // "broker")))

let agy_payload ?(workspace_paths = []) event =
  let ws =
    `List (List.map (fun p -> `String p) workspace_paths)
  in
  Yojson.Safe.to_string
    (`Assoc
       [ ("hook_event_name", `String event)
       ; ("session_id", `String sid)
       ; ("conversationId", `String sid)
       ; ("workspacePaths", ws)
       ])

(* THE #69 REGRESSION. The row must land in the WORKSPACE's broker, never in
   `default`, when the payload names a workspace. *)
let test_vanilla_registers_into_workspace_broker () =
  with_ctx (fun ctx ->
    let ws = make_workspace ctx ~name:"ws" in
    let hook_cwd = make_hook_cwd ctx in
    let rc, _, err =
      fire_vanilla ctx ~hook_cwd ~args:"hook agy SessionStart"
        ~stdin_payload:(agy_payload ~workspace_paths:[ ws ] "SessionStart")
    in
    check int ("SessionStart exit 0 (stderr: " ^ err ^ ")") 0 rc;
    let fps = fingerprints_holding ctx ~session_id:sid in
    check int
      (Printf.sprintf "registered into exactly one broker (got: [%s])"
         (String.concat "; " fps))
      1 (List.length fps);
    check bool
      (Printf.sprintf
         "#69: vanilla agy must not register into the `default` broker (got: %s)"
         (String.concat "; " fps))
      false
      (List.mem "default" fps))

(* The workspace must also reach the registration row, so the worktree-mismatch
   guard has something to check (#68 — the same payload field answers both). *)
let test_vanilla_records_workspace_as_cwd () =
  with_ctx (fun ctx ->
    let ws = make_workspace ctx ~name:"wscwd" in
    let hook_cwd = make_hook_cwd ctx in
    let rc, _, err =
      fire_vanilla ctx ~hook_cwd ~args:"hook agy SessionStart"
        ~stdin_payload:(agy_payload ~workspace_paths:[ ws ] "SessionStart")
    in
    check int ("SessionStart exit 0 (stderr: " ^ err ^ ")") 0 rc;
    match fingerprints_holding ctx ~session_id:sid with
    | [ fp ] -> (
        let row =
          List.find_opt
            (fun row -> field row "session_id" = Some (`String sid))
            (rows_at (repos_dir ctx // fp // "broker"))
        in
        match row with
        | None -> fail "row vanished between lookups"
        | Some row ->
            check bool
              (Printf.sprintf "#68: row records the workspace as cwd (got: %s)"
                 (match field row "cwd" with
                  | Some (`String c) -> c
                  | _ -> "<none>"))
              true
              (field row "cwd" = Some (`String ws)))
    | fps -> failf "expected one broker, got [%s]" (String.concat "; " fps))

(* MANAGED MUST NOT REGRESS. `c2c start agy` exports C2C_MCP_BROKER_ROOT and
   hook children inherit it; that export stays authoritative even when the
   payload names a different workspace. Without this, the #69 fix would
   silently relocate every managed agy session. *)
let test_managed_broker_root_env_still_wins () =
  with_ctx (fun ctx ->
    let ws = make_workspace ctx ~name:"wsmanaged" in
    let hook_cwd = make_hook_cwd ctx in
    let rc, _, err =
      fire_vanilla ctx ~hook_cwd ~args:"hook agy SessionStart"
        ~stdin_payload:(agy_payload ~workspace_paths:[ ws ] "SessionStart")
        ~extra_env:[ ("C2C_MCP_BROKER_ROOT", ctx.broker_root) ]
    in
    check int ("SessionStart exit 0 (stderr: " ^ err ^ ")") 0 rc;
    check bool "managed: row lands in the exported broker root" true
      (row_for ctx ~session_id:sid <> None);
    check int
      "managed: nothing written to any workspace-fingerprinted broker" 0
      (List.length (fingerprints_holding ctx ~session_id:sid)))

(* NO WORKSPACE IS A REAL STATE, NOT A BUG — `agy -p` without --add-dir has
   none. We must not guess one, but we must not register into `default`
   silently either: the row is then unaddressable from the repo the operator
   thinks they are in, with nothing anywhere saying so. Record it durably
   where `c2c dev tail-log` / doctor can find it, mirroring the
   `managed_registration_failed` treatment in `c2c start kimi` (#40 F5). *)
let test_absent_workspace_is_recorded_not_silent () =
  with_ctx (fun ctx ->
    let hook_cwd = make_hook_cwd ctx in
    let rc, _, err =
      fire_vanilla ctx ~hook_cwd ~args:"hook agy SessionStart"
        ~stdin_payload:(agy_payload ~workspace_paths:[] "SessionStart")
    in
    check int ("SessionStart exit 0 (stderr: " ^ err ^ ")") 0 rc;
    let log = repos_dir ctx // "default" // "broker" // "broker.log" in
    let contents = read_file log in
    let mentions needle =
      let nl = String.length needle and cl = String.length contents in
      let rec loop i =
        if i + nl > cl then false
        else if String.sub contents i nl = needle then true
        else loop (i + 1)
      in
      loop 0
    in
    check bool
      ("#69: fallback to the `default` broker must be recorded in broker.log \
        (log: " ^ log ^ ")")
      true
      (mentions "agy_workspace_unresolved"))

let () =
  Random.self_init ();
  run "c2c_hook_agy"
    [ ( "hook_agy_broker_root"
      , [ test_case "#69 vanilla registers into the workspace broker" `Quick
            test_vanilla_registers_into_workspace_broker
        ; test_case "#68 vanilla records the workspace as cwd" `Quick
            test_vanilla_records_workspace_as_cwd
        ; test_case "#69 managed C2C_MCP_BROKER_ROOT still wins" `Quick
            test_managed_broker_root_env_still_wins
        ; test_case "#69 absent workspace is recorded, not silent" `Quick
            test_absent_workspace_is_recorded_not_silent
        ] )
    ; ( "hook_agy_turn_end"
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
