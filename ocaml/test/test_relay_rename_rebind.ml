(* B179: rename → relay identity rebind.

   After a successful local alias rename, the new name must be re-registered
   on the configured relay under the same Ed25519 identity. Without that,
   monitor relay peeks fail TERMINAL with
   "unauthorized: alias \"<new>\" has no identity binding".

   Coverage:
   - skip when no relay URL is configured
   - next_step_command is copy-pasteable
   - merge_into_rename_result embeds relay_rebind
   - against production loopback relay (Relay_test_support_real):
     * rebind_lwt binds the new alias
     * old alias remains dual-bound until TTL (defined lease state)
     * broker rename_alias + rebind composes end-to-end
     * unreachable relay surfaces status=error + next_step (non-fatal)
*)

open Alcotest
module RTSR = Relay_test_support_real

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-b179-%08x" (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let json_status = function
  | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

let json_str key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

let with_env_cleared keys f =
  let saved =
    List.map (fun k -> (k, Sys.getenv_opt k)) keys
  in
  List.iter
    (fun k ->
      (* Unix.putenv "" is the portable "unset" used elsewhere in this tree. *)
      Unix.putenv k "")
    keys;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (k, v) ->
          match v with
          | Some s -> Unix.putenv k s
          | None -> Unix.putenv k "")
        saved)
    f

let with_identity_path path f =
  let prev = Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" in
  Unix.putenv "C2C_RELAY_IDENTITY_PATH" path;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_RELAY_IDENTITY_PATH"
        (Option.value prev ~default:""))
    f

let test_next_step_command () =
  check string "next step names register + alias flag"
    "c2c relay register --alias=gk-black"
    (Relay_rename_rebind.next_step_command ~new_alias:"gk-black")

let test_skip_when_no_relay_url () =
  with_env_cleared
    [ "C2C_RELAY_URL"; "C2C_RELAY_CONFIG"; "C2C_MCP_BROKER_ROOT"; "C2C_RELAY_TOKEN" ]
    (fun () ->
      (* Point HOME at a temp dir so ~/.config/c2c/relay.json cannot
         accidentally configure a URL. *)
      with_temp_dir (fun home ->
          let prev_home = Sys.getenv_opt "HOME" in
          let prev_xdg = Sys.getenv_opt "XDG_CONFIG_HOME" in
          Unix.putenv "HOME" home;
          Unix.putenv "XDG_CONFIG_HOME" (Filename.concat home ".config");
          Fun.protect
            ~finally:(fun () ->
              (match prev_home with
               | Some h -> Unix.putenv "HOME" h
               | None -> Unix.putenv "HOME" "");
              (match prev_xdg with
               | Some x -> Unix.putenv "XDG_CONFIG_HOME" x
               | None -> Unix.putenv "XDG_CONFIG_HOME" ""))
            (fun () ->
              check (option string) "no relay url" None
                (Relay_rename_rebind.resolve_relay_url ());
              let j =
                Relay_rename_rebind.rebind_sync ~old_alias:"rn-old"
                  ~new_alias:"rn-new" ()
              in
              check string "status skipped" "skipped" (json_status j);
              check string "reason" "no relay URL configured"
                (json_str "reason" j))))

let test_merge_into_rename_result () =
  let rename =
    `Assoc
      [ ("ok", `Bool true)
      ; ("old_alias", `String "a")
      ; ("new_alias", `String "b")
      ]
  in
  let rebind =
    `Assoc
      [ ("status", `String "error")
      ; ("next_step", `String "c2c relay register --alias=b")
      ]
  in
  let merged =
    Relay_rename_rebind.merge_into_rename_result ~rename_json:rename
      ~rebind_json:rebind
  in
  match merged with
  | `Assoc fields ->
      check bool "ok preserved" true
        (List.assoc_opt "ok" fields = Some (`Bool true));
      check bool "relay_rebind present" true
        (List.mem_assoc "relay_rebind" fields);
      (match List.assoc "relay_rebind" fields with
       | `Assoc rb ->
           check string "next_step" "c2c relay register --alias=b"
             (match List.assoc_opt "next_step" rb with
              | Some (`String s) -> s
              | _ -> "")
       | _ -> fail "relay_rebind not assoc")
  | _ -> fail "merged not assoc"

let test_rebind_binds_new_alias_on_live_relay () =
  with_temp_dir (fun dir ->
      let id_path = Filename.concat dir "identity.json" in
      with_identity_path id_path (fun () ->
          RTSR.with_server (fun ~base_url ~relay ->
              let open Lwt.Infix in
              let id =
                Relay_identity.load_or_create_at ~path:id_path
                  ~alias_hint:"b179-old"
              in
              (* First bind old alias so we can assert dual-bind after. *)
              let p_old =
                Relay_signed_ops.sign_register id ~alias:"b179-old"
                  ~relay_url:base_url
              in
              let client =
                Relay.Relay_client.make ~timeout:5.0 base_url
              in
              Relay.Relay_client.register_signed client
                ~node_id:"cli-b179-old" ~session_id:"cli-b179-old"
                ~alias:"b179-old" ~client_type:"cli"
                ~identity_pk_b64:p_old.identity_pk_b64
                ~sig_b64:p_old.sig_b64 ~nonce:p_old.nonce ~ts:p_old.ts ()
              >>= fun reg_old ->
              check bool "old register ok" true
                (match reg_old with
                 | `Assoc f -> List.assoc_opt "ok" f = Some (`Bool true)
                 | _ -> false);
              Relay_rename_rebind.rebind_lwt ~relay_url:base_url
                ~old_alias:"b179-old" ~new_alias:"b179-new" ()
              >>= fun j ->
              check string "rebind ok" "ok" (json_status j);
              check string "old lease dual-bind"
                "dual_bind_until_ttl" (json_str "old_alias_lease" j);
              check string "next_step empty on success" ""
                (json_str "next_step" j);
              let new_pk =
                Relay.InMemoryRelay.identity_pk_of relay ~alias:"b179-new"
              in
              let old_pk =
                Relay.InMemoryRelay.identity_pk_of relay ~alias:"b179-old"
              in
              check bool "new alias has identity binding" true
                (Option.is_some new_pk);
              check bool "old alias still dual-bound until TTL" true
                (Option.is_some old_pk);
              check bool "same identity key" true (new_pk = old_pk);
              Lwt.return_unit)))

let test_rename_then_rebind_end_to_end () =
  with_temp_dir (fun dir ->
      let id_path = Filename.concat dir "identity.json" in
      let broker_root = Filename.concat dir "broker" in
      Unix.mkdir broker_root 0o700;
      with_identity_path id_path (fun () ->
          RTSR.with_server (fun ~base_url ~relay ->
              let open Lwt.Infix in
              let id =
                Relay_identity.load_or_create_at ~path:id_path
                  ~alias_hint:"b179-rn-old"
              in
              let client =
                Relay.Relay_client.make ~timeout:5.0 base_url
              in
              let p =
                Relay_signed_ops.sign_register id ~alias:"b179-rn-old"
                  ~relay_url:base_url
              in
              Relay.Relay_client.register_signed client
                ~node_id:"cli-b179-rn-old" ~session_id:"cli-b179-rn-old"
                ~alias:"b179-rn-old" ~client_type:"cli"
                ~identity_pk_b64:p.identity_pk_b64 ~sig_b64:p.sig_b64
                ~nonce:p.nonce ~ts:p.ts ()
              >>= fun _ ->
              (* Local rename (sync broker path) then async rebind. *)
              let broker = C2c_mcp.Broker.create ~root:broker_root in
              C2c_mcp.Broker.register broker ~session_id:"b179-sess"
                ~alias:"b179-rn-old" ~pid:None ~pid_start_time:None ();
              (match
                 C2c_mcp.Broker.rename_alias broker ~session_id:"b179-sess"
                   ~new_alias:"b179-rn-new"
               with
               | Error e -> fail ("local rename failed: " ^ e)
               | Ok rename_json ->
                   Relay_rename_rebind.rebind_lwt ~relay_url:base_url
                     ~old_alias:"b179-rn-old" ~new_alias:"b179-rn-new" ()
                   >>= fun rebind_json ->
                   let merged =
                     Relay_rename_rebind.merge_into_rename_result
                       ~rename_json ~rebind_json
                   in
                   check string "rebind status ok" "ok"
                     (match merged with
                      | `Assoc fields ->
                          (match List.assoc_opt "relay_rebind" fields with
                           | Some j -> json_status j
                           | None -> "")
                      | _ -> "");
                   check bool "new alias bound on relay" true
                     (Option.is_some
                        (Relay.InMemoryRelay.identity_pk_of relay
                           ~alias:"b179-rn-new"));
                   let regs = C2c_mcp.Broker.list_registrations broker in
                   let row =
                     List.find
                       (fun r -> r.C2c_mcp.session_id = "b179-sess")
                       regs
                   in
                   check string "local registry renamed" "b179-rn-new"
                     row.alias;
                   Lwt.return_unit))))

let test_unreachable_relay_surfaces_next_step () =
  with_temp_dir (fun dir ->
      let id_path = Filename.concat dir "identity.json" in
      with_identity_path id_path (fun () ->
          ignore
            (Relay_identity.load_or_create_at ~path:id_path
               ~alias_hint:"b179-dead");
          (* Bind a port then close it — connection refused. *)
          let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
          Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
          let port =
            match Unix.getsockname sock with
            | Unix.ADDR_INET (_, p) -> p
            | _ -> failwith "expected inet"
          in
          Unix.close sock;
          let url = Printf.sprintf "http://127.0.0.1:%d" port in
          let j =
            Relay_rename_rebind.rebind_sync ~relay_url:url
              ~old_alias:"b179-dead-old" ~new_alias:"b179-dead-new" ()
          in
          check string "status error" "error" (json_status j);
          check string "next_step copy-pasteable"
            "c2c relay register --alias=b179-dead-new"
            (json_str "next_step" j);
          check bool "error non-empty" true
            (String.trim (json_str "error" j) <> "")))

let () =
  Random.self_init ();
  Alcotest.run "relay_rename_rebind"
    [ ( "b179"
      , [ test_case "next_step_command" `Quick test_next_step_command
        ; test_case "skip when no relay URL" `Quick
            test_skip_when_no_relay_url
        ; test_case "merge into rename result" `Quick
            test_merge_into_rename_result
        ; test_case "rebind binds new alias on live relay" `Quick
            test_rebind_binds_new_alias_on_live_relay
        ; test_case "rename then rebind end-to-end" `Quick
            test_rename_then_rebind_end_to_end
        ; test_case "unreachable relay surfaces next_step" `Quick
            test_unreachable_relay_surfaces_next_step
        ] )
    ]
