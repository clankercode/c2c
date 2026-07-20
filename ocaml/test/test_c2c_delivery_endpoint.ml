open Alcotest

let test_kimi_registered () =
  check bool "kimi in registry" true
    (List.mem "kimi" (C2c_delivery_endpoint.list_kinds ()))

let test_find_kimi () =
  match C2c_delivery_endpoint.find "kimi" with
  | None -> fail "kimi adapter missing"
  | Some (module A) ->
      check string "kind" "kimi" A.kind;
      check string "drain" "after_push"
        (C2c_delivery_endpoint.drain_policy_to_string A.drain_policy)

let test_endpoint_of_reg () =
  let reg : C2c_mcp.registration =
    { session_id = "s1"
    ; alias = "a1"
    ; pid = None
    ; pid_start_time = None
    ; registered_at = Some 1.0
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type = Some "kimi"
    ; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
    ; herdr_pane = None
    ; herdr_socket = None
    ; cwd = Some "/tmp/ws"
    ; metadata_opt_out = false
    ; registered_by = Some "kimi-hook"
    ; opaque_host_id = None
    }
  in
  (match C2c_delivery_endpoint.endpoint_of_kimi_reg ~broker_root:"/b" reg with
   | Some ep ->
       check string "kind" "kimi" ep.kind;
       check string "workdir" "/tmp/ws" (Option.get ep.workdir)
   | None -> fail "expected endpoint");
  let no_cwd = { reg with cwd = None } in
  check bool "no cwd" true
    (C2c_delivery_endpoint.endpoint_of_kimi_reg ~broker_root:"/b" no_cwd = None)

let test_agy_registered () =
  check bool "agy in registry" true
    (List.mem "agy" (C2c_delivery_endpoint.list_kinds ()));
  check bool "two adapters" true
    (List.length (C2c_delivery_endpoint.list_kinds ()) >= 2)

let test_endpoint_of_agy_reg () =
  let reg : C2c_mcp.registration =
    { session_id = "agy-sid"
    ; alias = "agy-a"
    ; pid = None
    ; pid_start_time = None
    ; registered_at = Some 1.0
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type = Some "agy"
    ; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
    ; herdr_pane = None
    ; herdr_socket = None
    ; cwd = Some "/tmp/agy"
    ; metadata_opt_out = false
    ; registered_by = Some "agy-hook"
    ; opaque_host_id = None
    }
  in
  match C2c_delivery_endpoint.endpoint_of_agy_reg ~broker_root:"/b" reg with
  | Some ep -> check string "kind" "agy" ep.kind
  | None -> fail "expected agy endpoint"

let () =
  run "c2c delivery endpoint (P3 C1 / P4 agy)"
    [ ( "registry"
      , [ test_case "kimi registered" `Quick test_kimi_registered
        ; test_case "find kimi" `Quick test_find_kimi
        ; test_case "endpoint_of_kimi_reg" `Quick test_endpoint_of_reg
        ; test_case "agy registered (>=2 adapters)" `Quick test_agy_registered
        ; test_case "endpoint_of_agy_reg" `Quick test_endpoint_of_agy_reg
        ] )
    ]
