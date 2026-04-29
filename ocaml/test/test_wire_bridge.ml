(** Cross-impl parity tests: OCaml wire bridge vs Python c2c_kimi_wire_bridge.py.

    These tests verify that the OCaml envelope formatting produces output
    identical to the Python reference implementation. *)

let msg ?(from_alias="") ?(to_alias="") ?(reply_via=None) ?(enc_status=None) content =
  C2c_mcp.{ from_alias; to_alias; content; deferrable = false; reply_via; enc_status; ts = 0.0; ephemeral = false; message_id = None }

(* ---------------------------------------------------------------------------
 * format_envelope parity (vs Python format_c2c_envelope)
 * --------------------------------------------------------------------------- *)

let test_envelope_basic () =
  let m = msg ~from_alias:"alice" ~to_alias:"bob" "hello world" in
  let got = C2c_wire_bridge.format_envelope m in
  let expected =
    "<c2c event=\"message\" from=\"alice\" to=\"bob\" source=\"broker\" reply_via=\"c2c_send\" action_after=\"continue\">\nhello world\n</c2c>"
  in
  Alcotest.(check string) "basic envelope" expected got

let test_envelope_xml_escaping () =
  (* ampersand, angle brackets, and quotes in sender/alias/content must be escaped *)
  let m = msg ~from_alias:"a&b" ~to_alias:"<x>" "say hi and bye" in
  let got = C2c_wire_bridge.format_envelope m in
  (* Python html.escape with quote=True escapes ampersand, angle brackets, quotes *)
  Alcotest.(check bool) "from attr escapes &"
    true (String.sub got 0 100 |> fun s ->
            let needle = "from=\"a&amp;b\"" in
            let nl = String.length needle and ll = String.length s in
            let rec f i = i + nl <= ll && (String.sub s i nl = needle || f (i+1)) in f 0);
  Alcotest.(check bool) "alias attr escapes <>"
    true (let needle = "alias=\"&lt;x&gt;\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_envelope_multiline_content () =
  let m = msg ~from_alias:"agent1" ~to_alias:"agent2" "line1\nline2\nline3" in
  let got = C2c_wire_bridge.format_envelope m in
  Alcotest.(check bool) "content preserved"
    true (let needle = "line1\nline2\nline3" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_envelope_empty_from () =
  let m = msg ~from_alias:"" ~to_alias:"target" "body" in
  let got = C2c_wire_bridge.format_envelope m in
  Alcotest.(check bool) "empty from_alias renders as empty"
    true (let needle = "from=\"\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

(* ---- Role attribute in envelope (slice #150) ---- *)

let test_envelope_with_role () =
  let m = msg ~from_alias:"alice" ~to_alias:"bob" "hello" in
  let role : string option = Some "coder" in
  let got = C2c_wire_bridge.format_envelope ?sender_role:role m in
  Alcotest.(check bool) "role attr emitted"
    true (let needle = "role=\"coder\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_envelope_role_xml_escaped () =
  (* role value with special chars must be escaped *)
  let m = msg ~from_alias:"alice" ~to_alias:"bob" "hello" in
  let role : string option = Some "a&b" in
  let got = C2c_wire_bridge.format_envelope ?sender_role:role m in
  Alcotest.(check bool) "role value escaped"
    true (let needle = "role=\"a&amp;b\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_envelope_role_absent_when_none () =
  (* absent sender_role must not emit any role attr *)
  let m = msg ~from_alias:"alice" ~to_alias:"bob" "hello" in
  let got = C2c_wire_bridge.format_envelope m in
  Alcotest.(check bool) "no role attr when sender_role is None"
    false (let needle = "role=" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_prompt_with_role_lookup () =
  let m1 = msg ~from_alias:"alice" ~to_alias:"bob" "hello" in
  let m2 = msg ~from_alias:"carol" ~to_alias:"bob" "world" in
  let lookup : string -> string option = function
    | "alice" -> Some "coordinator"
    | "carol" -> Some "reviewer"
    | _ -> None
  in
  let got = C2c_wire_bridge.format_prompt ~role_lookup:lookup [m1; m2] in
  (* Check alice's envelope has role="coordinator" *)
  Alcotest.(check bool) "alice role present"
    true (let needle = "role=\"coordinator\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0);
  (* Check carol's envelope has role="reviewer" *)
  Alcotest.(check bool) "carol role present"
    true (let needle = "role=\"reviewer\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0);
  (* Check alice's from_alias is in output *)
  Alcotest.(check bool) "alice from_alias present"
    true (let needle = "from=\"alice\"" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

let test_prompt_role_omitted_when_lookup_returns_none () =
  let m = msg ~from_alias:"unknown" ~to_alias:"bob" "hello" in
  let lookup (_ : string) : string option = None in
  let got = C2c_wire_bridge.format_prompt ~role_lookup:lookup [m] in
  Alcotest.(check bool) "no role attr for unknown sender"
    false (let needle = "role=" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

(* ---------------------------------------------------------------------------
 * format_prompt parity (vs Python format_prompt = "\n\n".join(...))
 * --------------------------------------------------------------------------- *)

let test_prompt_single () =
  let m = msg ~from_alias:"a" ~to_alias:"b" "hello" in
  let got = C2c_wire_bridge.format_prompt [m] in
  let expected = C2c_wire_bridge.format_envelope m in
  Alcotest.(check string) "single-message prompt equals envelope" expected got

let test_prompt_multiple () =
  let m1 = msg ~from_alias:"a" ~to_alias:"b" "first" in
  let m2 = msg ~from_alias:"c" ~to_alias:"b" "second" in
  let got = C2c_wire_bridge.format_prompt [m1; m2] in
  (* Python: "\n\n".join([envelope1, envelope2]) *)
  let e1 = C2c_wire_bridge.format_envelope m1 in
  let e2 = C2c_wire_bridge.format_envelope m2 in
  let expected = e1 ^ "\n\n" ^ e2 in
  Alcotest.(check string) "two-message prompt joined with blank line" expected got

let test_prompt_empty () =
  let got = C2c_wire_bridge.format_prompt [] in
  Alcotest.(check string) "empty prompt is empty string" "" got

(* ---------------------------------------------------------------------------
 * Spool round-trip
 * --------------------------------------------------------------------------- *)

let with_tmp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name = Printf.sprintf "c2c-wire-bridge-%d-%d" (Unix.getpid ()) (Random.bits ()) in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "spool.json") with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir)

let test_spool_roundtrip () =
  with_tmp_dir (fun dir ->
    let path = Filename.concat dir "spool.json" in
    let sp = C2c_wire_bridge.spool_of_path path in
    let msgs =
      [ msg ~from_alias:"alice" ~to_alias:"bob" "hello"
      ; msg ~from_alias:"carol" ~to_alias:"bob" "world"
      ]
    in
    C2c_wire_bridge.spool_write sp msgs;
    let got = C2c_wire_bridge.spool_read sp in
    Alcotest.(check int) "roundtrip count" 2 (List.length got);
    Alcotest.(check string) "first from_alias" "alice" (List.nth got 0).from_alias;
    Alcotest.(check string) "second content"   "world" (List.nth got 1).content)

let test_spool_clear () =
  with_tmp_dir (fun dir ->
    let path = Filename.concat dir "spool.json" in
    let sp = C2c_wire_bridge.spool_of_path path in
    let msgs = [ msg ~from_alias:"x" ~to_alias:"y" "test" ] in
    C2c_wire_bridge.spool_write sp msgs;
    C2c_wire_bridge.spool_clear sp;
    let got = C2c_wire_bridge.spool_read sp in
    Alcotest.(check int) "clear leaves empty spool" 0 (List.length got))

let test_spool_missing_file () =
  let sp = C2c_wire_bridge.spool_of_path "/nonexistent/path/spool.json" in
  let got = C2c_wire_bridge.spool_read sp in
  Alcotest.(check int) "missing spool reads as empty" 0 (List.length got)

(* ---------------------------------------------------------------------------
 * xml_escape matches Python html.escape(str, quote=True)
 * --------------------------------------------------------------------------- *)

let test_xml_escape_amp () =
  (* Only test via envelope since xml_escape is not exported *)
  let m = msg ~from_alias:"a&b" ~to_alias:"c" "x" in
  let got = C2c_wire_bridge.format_envelope m in
  Alcotest.(check bool) "& → &amp;"
    true (let needle = "a&amp;b" in
            let nl = String.length needle and ll = String.length got in
            let rec f i = i + nl <= ll && (String.sub got i nl = needle || f (i+1)) in f 0)

(* ---------------------------------------------------------------------------
 * Registration
 * --------------------------------------------------------------------------- *)

let () =
  Alcotest.run "wire_bridge"
    [ ( "envelope"
      , [ Alcotest.test_case "basic"           `Quick test_envelope_basic
        ; Alcotest.test_case "xml_escaping"    `Quick test_envelope_xml_escaping
        ; Alcotest.test_case "multiline"       `Quick test_envelope_multiline_content
        ; Alcotest.test_case "empty_from"      `Quick test_envelope_empty_from
        ; Alcotest.test_case "with_role"       `Quick test_envelope_with_role
        ; Alcotest.test_case "role_xml_escaped" `Quick test_envelope_role_xml_escaped
        ; Alcotest.test_case "role_absent_when_none" `Quick test_envelope_role_absent_when_none
        ] )
    ; ( "prompt"
      , [ Alcotest.test_case "single"          `Quick test_prompt_single
        ; Alcotest.test_case "multiple"        `Quick test_prompt_multiple
        ; Alcotest.test_case "empty"           `Quick test_prompt_empty
        ; Alcotest.test_case "with_role_lookup" `Quick test_prompt_with_role_lookup
        ; Alcotest.test_case "role_omitted_when_none" `Quick test_prompt_role_omitted_when_lookup_returns_none
        ] )
    ; ( "spool"
      , [ Alcotest.test_case "roundtrip"       `Quick test_spool_roundtrip
        ; Alcotest.test_case "clear"           `Quick test_spool_clear
        ; Alcotest.test_case "missing_file"    `Quick test_spool_missing_file
        ] )
    ; ( "escape"
      , [ Alcotest.test_case "ampersand"       `Quick test_xml_escape_amp
        ] )
    ]
