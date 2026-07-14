(* c2c_supervisor_cmd — human-friendly supervisor reply commands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers

(* --- subcommand group: supervisor ----------------------------------------- *)
(* Human-friendly wrappers for replying to question.asked / permission.asked
   sentinels without crafting raw protocol strings by hand. *)

let supervisor_send ~to_alias ~content =
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:None broker in
  (try
     C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content ();
     (* B088: a remote [alias@host] target is only queued to the local relay
        outbox here, never synchronously delivered — never report it as a
        delivered [ok ->]. Supervisor replies are normally local peers; this
        just keeps the output honest if a cross-host target is ever used. *)
     if C2c_mcp.Broker.is_remote_alias to_alias then begin
       Printf.printf "queued -> %s (from %s)\n" to_alias from_alias;
       (* Share B177 / B088 connector honesty with `c2c send`. *)
       Printf.eprintf "warning: %s\n%!" (C2c_send_cmd.remote_queued_warning ())
     end else
       Printf.printf "ok -> %s (from %s)\n" to_alias from_alias
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg; exit 1)

let supervisor_answer_cmd =
  let open Cmdliner.Term in
  const (fun peer qid answer ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "question:%s:answer:%s" qid answer))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Question request ID (from the DM notification).")
  $ Cmdliner.Arg.(required & pos 2 (some string) None & info [] ~docv:"ANSWER" ~doc:"Free-text answer or selected option.")

let supervisor_reject_question_cmd =
  let open Cmdliner.Term in
  const (fun peer qid ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "question:%s:reject" qid))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Question request ID.")

let supervisor_approve_cmd =
  let open Cmdliner.Term in
  let always_flag = Cmdliner.Arg.(value & flag & info ["always"] ~doc:"Grant permanent approval (approve-always) instead of once.") in
  const (fun peer permid always ->
    let decision = if always then "approve-always" else "approve-once" in
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "permission:%s:%s" permid decision))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER"   ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"     ~doc:"Permission request ID (from the DM notification).")
  $ always_flag

let supervisor_reject_permission_cmd =
  let open Cmdliner.Term in
  const (fun peer permid ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "permission:%s:reject" permid))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Permission request ID.")

let supervisor_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "supervisor"
       ~doc:"Human-friendly replies to agent permission and question requests."
       ~man:[ `S "DESCRIPTION"
            ; `P "Wrappers that send structured reply sentinels to an agent's \
                  inbox without requiring you to craft the raw protocol strings."
            ; `S "EXAMPLES"
            ; `P "$(b,c2c supervisor answer oc-coder1 abc123 \"yes\")"
            ; `P "$(b,c2c supervisor question-reject oc-coder1 abc123)"
            ; `P "$(b,c2c supervisor approve oc-coder1 perm456)"
            ; `P "$(b,c2c supervisor approve --always oc-coder1 perm456)"
            ; `P "$(b,c2c supervisor reject oc-coder1 perm456)"
            ])
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "answer"
           ~doc:"Answer a question request (question.asked). Sends question:<ID>:answer:<ANSWER>.")
        supervisor_answer_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "question-reject"
           ~doc:"Reject a question request. Sends question:<ID>:reject.")
        supervisor_reject_question_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "approve"
           ~doc:"Approve a permission request (permission.asked). Use --always for permanent approval.")
        supervisor_approve_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "reject"
           ~doc:"Reject a permission request. Sends permission:<ID>:reject.")
        supervisor_reject_permission_cmd
    ]
