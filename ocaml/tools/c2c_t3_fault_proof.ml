(* Development-only proof harness. All actual sends use the native client and
   shared durable dispatcher. The only injected transport fault discards one
   successful receipt AFTER the stock server has accepted it. *)
open Lwt.Infix
module T3 = C2c_t3_client
module State = C2c_t3_state
module Service = C2c_t3_service
module Recovery = C2c_t3_recovery

let require = function Ok x -> x | Error _ -> failwith "proof operation refused"
let check ok = if not ok then failwith "proof assertion failed"
let receipt_json (r : T3.receipt) = `Assoc [
  "threadId", `String r.receipt_thread_id; "messageId", `String r.message_id;
  "runId", `String r.run_id ]
let write_private file json =
  let fd = Unix.openfile file [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> Yojson.Safe.to_channel channel json; output_char channel '\n'; flush channel; Unix.fsync fd)

let run action thread_id state_dir output gate =
  check (List.mem action ["inbound-loss"; "inbound-retry"; "recovery-loss";
                         "recovery-retry"; "recovery-race"]);
  let config_dir = require (T3.default_config_dir ()) in
  let t3_home = require (T3.resolve_home ()) in
  let client, runtime = require (T3.authorize ~config_dir ~t3_home ()) in
  check (runtime.server_version = Some "0.1.1");
  T3.initialize client >>= fun initialized ->
  ignore (require initialized);
  let generation = T3.credential_generation_of client in
  let environment_id = "fault-proof:" ^ runtime.t3_home in
  let state = require (State.open_state ~environment_id ~dir:state_dir ()) in
  Lwt.finalize (fun () ->
    let operations : Recovery.operations = {
      capabilities = (fun () -> T3.capabilities client);
      read_activity = (fun id -> T3.read_activity client ~thread_id:id ());
      list_queue = (fun id -> T3.list_queue client ~thread_id:id) } in
    let enqueue =
      if action = "inbound-loss" then (
        let nonce = "C2C_NATIVE_fault_" ^ Digest.to_hex (Digest.string state_dir) in
        let payload = `Assoc ["version", `Int 1; "kind", `String "inbound";
          "status", `String "pending"; "thread_id", `String thread_id;
          "formatted", `String ("BEGIN C2C DATA\n" ^ nonce ^ "\nEND C2C DATA");
          "request_id", `String ("c2c-fault-" ^ Digest.to_hex (Digest.string state_dir));
          "mode", `String "auto"; "attempts", `Int 0;
          "next_attempt_at", `Float 0.] in
        check (State.journal_pending state = []);
        ignore (require (State.journal_append state ~kind:State.Inbound ~key:nonce ~payload));
        Lwt.return_unit)
      else if action = "recovery-loss" || action = "recovery-race" then
        Recovery.sweep ~client ~state ~environment_id ~credential_generation:generation
          ~thread_ids:[thread_id] ~clock:Unix.gettimeofday () >|= fun result ->
        check (List.length result.enqueued = 1 && result.errors = [])
      else Lwt.return_unit in
    enqueue >>= fun () ->
    let send_calls = ref 0 in
    let preflight_calls = ref 0 in
    let accepted = ref [] in
    let send ~thread_id ~message ~mode ~client_request_id =
      incr send_calls;
      T3.send_message client ~thread_id ~message ~mode ~client_request_id >|= function
      | Ok receipt when action = "inbound-loss" || action = "recovery-loss" ->
          accepted := receipt_json receipt :: !accepted;
          Error (T3.Timeout "injected: accepted receipt deliberately discarded")
      | Ok receipt -> accepted := receipt_json receipt :: !accepted; Ok receipt
      | Error error -> Error error in
    let preflight (entry : State.entry) =
      incr preflight_calls;
      if entry.State.kind <> State.Recovery then Lwt.return (Ok ())
      else match Recovery.candidate_of_entry entry with
      | Error reason -> Lwt.return (Error reason)
      | Ok candidate ->
          Recovery.preflight_with ~operations ~environment_id
            ~credential_generation:generation ~candidate () >>= function
          | Error _ as error -> Lwt.return error
          | Ok () when action = "recovery-race" ->
              write_private (gate ^ ".ready") (`Assoc ["preflightPassed", `Bool true]);
              let deadline = Unix.gettimeofday () +. 30. in
              let rec wait () =
                if Sys.file_exists (gate ^ ".release") then Lwt.return (Ok ())
                else if Unix.gettimeofday () >= deadline then Lwt.return (Error "race gate timed out")
                else Lwt_unix.sleep 0.05 >>= wait in
              wait ()
          | Ok () -> Lwt.return (Ok ()) in
    let dispatcher = Service.create_dispatcher ~state ~send ~preflight
      ~credential_identity:(fun () -> T3.credential_identity_of client)
      ~credential_generation:(fun () -> generation) ~clock:Unix.gettimeofday () in
    let rec dispatch remaining =
      check (remaining > 0);
      Service.dispatch_once dispatcher >>= function
      | Service.Waiting seconds ->
          check (seconds >= 0. && seconds <= 2.);
          Lwt_unix.sleep seconds >>= fun () -> dispatch (remaining - 1)
      | step -> Lwt.return step in
    dispatch 4 >>= fun step ->
    let step_name = match step with
      | Service.Submitted _ -> "submitted" | Service.Retained _ -> "retained"
      | Service.Held _ -> "held" | Service.Idle -> "idle"
      | Service.Waiting _ -> "waiting" | Service.Rebind_required _ -> "rebind_required" in
    let credential_fence_held = match step with
      | Service.Held reason ->
          String.starts_with ~prefix:"uncertain submission: credential" reason
      | _ -> false in
    let pending = State.journal_pending state |> List.map (fun (entry : State.entry) ->
      let fields = ["status"; "uncertain"; "attempts"; "credential_generation"; "credential_identity"; "request_id"] in
      `Assoc (List.map (fun key -> key, Yojson.Safe.Util.member key entry.payload) fields)) in
    write_private output (`Assoc ["action", `String action;
      "credentialGeneration", `Int generation; "step", `String step_name;
      "credentialIdentity", `String (T3.credential_identity_of client);
      "sendCalls", `Int !send_calls; "accepted", `List (List.rev !accepted);
      "preflightCalls", `Int !preflight_calls;
      "credentialFenceHeld", `Bool credential_fence_held;
      "pending", `List pending;
      "acknowledged", `Int (List.length (State.journal_acked state))]);
    Lwt.return_unit)
    (fun () -> State.close state; Lwt.return_unit)

let () =
  try
    check (Array.length Sys.argv = 7);
    check (Sys.argv.(6) = "owned-stock-t3-fixture-only");
    Lwt_main.run (run Sys.argv.(1) Sys.argv.(2) Sys.argv.(3) Sys.argv.(4) Sys.argv.(5));
    ()
  with _ -> prerr_endline "Native dispatcher fault proof failed (private artifacts retained)"; exit 1
