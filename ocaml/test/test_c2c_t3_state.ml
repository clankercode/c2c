(* Tests for C2c_t3_state: alias stability, mapping/tombstones, bounded
   durable journal, ownership checks, singleton lock. *)

module S = C2c_t3_state

let fresh_dir () =
  let base = Filename.temp_file "c2c-t3-state" "" in
  Sys.remove base;
  base

let rm_rf dir =
  ignore (Sys.command (Printf.sprintf "/bin/rm -rf %s" (Filename.quote dir)))

let with_dir f =
  let dir = fresh_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let open_ok ?max_journal ?max_payload_bytes ?max_tombstones ?max_acked dir =
  match S.open_state ?max_journal ?max_payload_bytes ?max_tombstones ?max_acked ~dir () with
  | Ok t -> t
  | Error e -> Alcotest.failf "open_state: %s" (S.open_error_to_string e)

let ok_or_fail = function Ok v -> v | Error e -> Alcotest.failf "unexpected error: %s" e
let is_error = function Error _ -> true | Ok _ -> false

let test_alias_stable () =
  (* sha256("abc") = ba7816bf8f01cfea... *)
  Alcotest.(check string) "known vector" "t3-ba7816bf8f01" (S.alias_of_thread_id "abc");
  Alcotest.(check string) "deterministic" (S.alias_of_thread_id "thread-1")
    (S.alias_of_thread_id "thread-1");
  Alcotest.(check bool) "distinct ids" true
    (S.alias_of_thread_id "a" <> S.alias_of_thread_id "b")

let test_mapping_persists () =
  with_dir (fun dir ->
    let t = open_ok dir in
    let m = ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1") in
    Alcotest.(check string) "alias" (S.alias_of_thread_id "thr-1") m.S.alias;
    let m2 = ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1") in
    Alcotest.(check int) "idempotent" 1 (List.length (S.mappings t));
    Alcotest.(check (float 0.)) "same created_at" m.S.created_at m2.S.created_at;
    Alcotest.(check bool) "empty id rejected" true (is_error (S.ensure_mapping t ~thread_id:""));
    S.close t;
    let t = open_ok dir in
    (match S.find_by_alias t ~alias:m.S.alias with
     | Some r -> Alcotest.(check string) "reloaded" "thr-1" r.S.thread_id
     | None -> Alcotest.fail "mapping lost across reopen");
    S.close t)

let test_tombstone () =
  with_dir (fun dir ->
    let t = open_ok dir in
    ignore (ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1"));
    Alcotest.(check bool) "unknown thread" true
      (is_error (S.tombstone t ~thread_id:"nope" ~reason:"x"));
    ok_or_fail (S.tombstone t ~thread_id:"thr-1" ~reason:"archived");
    ok_or_fail (S.tombstone t ~thread_id:"thr-1" ~reason:"second");
    Alcotest.(check bool) "ensure refused" true (is_error (S.ensure_mapping t ~thread_id:"thr-1"));
    S.close t;
    let t = open_ok dir in
    (match S.find_by_thread t ~thread_id:"thr-1" with
     | Some { S.tombstone = Some tb; _ } ->
       Alcotest.(check string) "first reason kept" "archived" tb.S.reason
     | _ -> Alcotest.fail "tombstone lost across reopen");
    S.close t)

let test_tombstone_bounded () =
  with_dir (fun dir ->
    let tick = ref 0. in
    let clock () = tick := !tick +. 1.; !tick in
    let t =
      match S.open_state ~clock ~max_tombstones:2 ~dir () with
      | Ok t -> t
      | Error e -> Alcotest.failf "%s" (S.open_error_to_string e)
    in
    List.iter
      (fun id ->
        ignore (ok_or_fail (S.ensure_mapping t ~thread_id:id));
        ok_or_fail (S.tombstone t ~thread_id:id ~reason:"r"))
      [ "a"; "b"; "c" ];
    Alcotest.(check bool) "oldest evicted" true (S.find_by_thread t ~thread_id:"a" = None);
    Alcotest.(check bool) "newer kept" true (S.find_by_thread t ~thread_id:"c" <> None);
    S.close t)

let test_journal_roundtrip () =
  with_dir (fun dir ->
    let t = open_ok dir in
    let payload = `Assoc [ ("text", `String "hi") ] in
    let e1 =
      match ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"m1" ~payload) with
      | S.Appended e -> e
      | S.Duplicate -> Alcotest.fail "unexpected duplicate"
    in
    Alcotest.(check bool) "dup pending" true
      (ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"m1" ~payload) = S.Duplicate);
    ignore (ok_or_fail (S.journal_append t ~kind:S.Recovery ~key:"m1" ~payload));
    Alcotest.(check int) "kinds are separate keyspaces" 2 (List.length (S.journal_pending t));
    Alcotest.(check int) "filter" 1 (List.length (S.journal_pending ~kind:S.Recovery t));
    S.close t;
    let t = open_ok dir in
    Alcotest.(check int) "survives reopen" 2 (List.length (S.journal_pending t));
    Alcotest.(check bool) "ack" true (ok_or_fail (S.journal_ack t ~seq:e1.S.seq));
    Alcotest.(check bool) "ack again" false (ok_or_fail (S.journal_ack t ~seq:e1.S.seq));
    Alcotest.(check bool) "acked key deduped" true
      (ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"m1" ~payload) = S.Duplicate);
    S.close t;
    let t = open_ok dir in
    Alcotest.(check bool) "dedup survives reopen" true
      (ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"m1" ~payload) = S.Duplicate);
    (match S.journal_append t ~kind:S.Inbound ~key:"m2" ~payload with
     | Ok (S.Appended e) ->
       Alcotest.(check bool) "seq never reused" true (e.S.seq > e1.S.seq)
     | _ -> Alcotest.fail "append m2");
    S.close t)

let test_journal_bounds () =
  with_dir (fun dir ->
    let t = open_ok ~max_journal:2 ~max_payload_bytes:32 ~max_acked:1 dir in
    let p = `String "x" in
    ignore (ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"a" ~payload:p));
    let b =
      match ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"b" ~payload:p) with
      | S.Appended e -> e
      | S.Duplicate -> Alcotest.fail "dup"
    in
    Alcotest.(check bool) "full refuses, never drops" true
      (is_error (S.journal_append t ~kind:S.Inbound ~key:"c" ~payload:p));
    Alcotest.(check int) "nothing evicted" 2 (List.length (S.journal_pending t));
    Alcotest.(check bool) "oversize payload" true
      (is_error
         (S.journal_append t ~kind:S.Recovery ~key:"big"
            ~payload:(`String (String.make 100 'x'))));
    ignore (ok_or_fail (S.journal_ack t ~seq:b.S.seq));
    ignore (ok_or_fail (S.journal_append t ~kind:S.Inbound ~key:"c" ~payload:p));
    (* acked ring holds 1: "b" is remembered, then "a"'s ack pushes it out. *)
    let a_seq = (List.hd (S.journal_pending t)).S.seq in
    ignore (ok_or_fail (S.journal_ack t ~seq:a_seq));
    Alcotest.(check bool) "b aged out of ring" true
      (match S.journal_append t ~kind:S.Inbound ~key:"b" ~payload:p with
       | Ok (S.Appended _) -> true | _ -> false);
    S.close t)

let test_file_mode () =
  with_dir (fun dir ->
    let t = open_ok dir in
    ignore (ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1"));
    let st = Unix.stat (S.state_path t) in
    Alcotest.(check int) "state.json 0600" 0o600 (st.Unix.st_perm land 0o777);
    Alcotest.(check int) "dir 0700" 0o700 ((Unix.stat dir).Unix.st_perm land 0o777);
    S.close t)

let test_unsafe_dir () =
  with_dir (fun dir ->
    Unix.mkdir dir 0o755;
    Unix.chmod dir 0o755;
    Alcotest.(check bool) "open dir refused" true
      (match S.open_state ~dir () with Error (S.Unsafe _) -> true | _ -> false))

let test_unsafe_file () =
  with_dir (fun dir ->
    let t = open_ok dir in
    ignore (ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1"));
    let path = S.state_path t in
    S.close t;
    Unix.chmod path 0o644;
    Alcotest.(check bool) "group/world-readable refused" true
      (match S.open_state ~dir () with Error (S.Unsafe _) -> true | _ -> false);
    Unix.chmod path 0o600;
    let target = Filename.concat dir "elsewhere" in
    Unix.rename path target;
    Unix.symlink target path;
    Alcotest.(check bool) "symlink refused" true
      (match S.open_state ~dir () with Error (S.Unsafe _) -> true | _ -> false);
    (* A refused open must have released the lock. *)
    Unix.unlink path;
    Unix.rename target path;
    S.close (open_ok dir))

let test_corrupt_not_overwritten () =
  with_dir (fun dir ->
    let t = open_ok dir in
    ignore (ok_or_fail (S.ensure_mapping t ~thread_id:"thr-1"));
    let path = S.state_path t in
    S.close t;
    let oc = open_out path in
    output_string oc "{not json";
    close_out oc;
    Unix.chmod path 0o600;
    Alcotest.(check bool) "corrupt reported" true
      (match S.open_state ~dir () with Error (S.Corrupt _) -> true | _ -> false);
    Alcotest.(check string) "left untouched" "{not json" (C2c_io.read_file path))

let test_singleton_in_process () =
  with_dir (fun dir ->
    let t = open_ok dir in
    Alcotest.(check bool) "second open refused" true
      (match S.open_state ~dir () with Error S.Already_running -> true | _ -> false);
    S.close t;
    S.close t;
    S.close (open_ok dir))

let test_singleton_cross_process () =
  with_dir (fun dir ->
    let t = open_ok dir in
    (match Unix.fork () with
     | 0 ->
       let code =
         match S.open_state ~dir () with
         | Error S.Already_running -> 0
         | _ -> 1
       in
       Unix._exit code
     | pid ->
       let _, status = Unix.waitpid [] pid in
       Alcotest.(check bool) "child saw Already_running" true (status = Unix.WEXITED 0));
    S.close t;
    (match Unix.fork () with
     | 0 ->
       let code = match S.open_state ~dir () with Ok _ -> 0 | Error _ -> 1 in
       Unix._exit code
     | pid ->
       let _, status = Unix.waitpid [] pid in
       Alcotest.(check bool) "child acquires after close" true (status = Unix.WEXITED 0)))

let () =
  Alcotest.run "c2c_t3_state"
    [ ( "alias", [ Alcotest.test_case "stable" `Quick test_alias_stable ] );
      ( "mapping",
        [ Alcotest.test_case "persists" `Quick test_mapping_persists;
          Alcotest.test_case "tombstone" `Quick test_tombstone;
          Alcotest.test_case "tombstone bounded" `Quick test_tombstone_bounded ] );
      ( "journal",
        [ Alcotest.test_case "roundtrip" `Quick test_journal_roundtrip;
          Alcotest.test_case "bounds" `Quick test_journal_bounds ] );
      ( "safety",
        [ Alcotest.test_case "file mode" `Quick test_file_mode;
          Alcotest.test_case "unsafe dir" `Quick test_unsafe_dir;
          Alcotest.test_case "unsafe file" `Quick test_unsafe_file;
          Alcotest.test_case "corrupt kept" `Quick test_corrupt_not_overwritten ] );
      ( "singleton",
        [ Alcotest.test_case "in process" `Quick test_singleton_in_process;
          Alcotest.test_case "cross process" `Quick test_singleton_cross_process ] ) ]
