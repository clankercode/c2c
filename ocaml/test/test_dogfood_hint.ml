(* Dogfood helper: exercises the wire-bridge and prints the
   actual output a receiving agent would see. Not part of the
   test suite (no Alcotest wrapper); for ad-hoc verification
   that the new hint lands. *)

let m_dm = C2c_mcp.{ from_alias = "alice"; to_alias = "bob"; content = "hi bob, please review #123"; deferrable = false; reply_via = Some "c2c_send"; enc_status = None; ts = 1700000000.0; ephemeral = false; message_id = None; pow_difficulty = None }
let m_room = C2c_mcp.{ from_alias = "alice"; to_alias = "bob#swarm-lounge"; content = "lounge ping"; deferrable = false; reply_via = Some "c2c_send"; enc_status = None; ts = 1700000000.0; ephemeral = false; message_id = None; pow_difficulty = None }
let m_relay = C2c_mcp.{ from_alias = "alice"; to_alias = "bob#abcdef012345"; content = "relay ping"; deferrable = false; reply_via = Some "c2c_send"; enc_status = None; ts = 1700000000.0; ephemeral = false; message_id = None; pow_difficulty = None }

let print_sep () = Printf.printf "\n==========\n"

let () =
  print_endline "=== DM (to_alias=bob) — wire-bridge default-ON ===";
  print_endline (C2c_wire_bridge.format_envelope m_dm);
  print_sep ();
  print_endline "=== Room (to_alias=bob#swarm-lounge) — wire-bridge default-ON ===";
  print_endline (C2c_wire_bridge.format_envelope m_room);
  print_sep ();
  print_endline "=== Relay DM (to_alias=bob#abcdef012345) — wire-bridge default-ON ===";
  print_endline (C2c_wire_bridge.format_envelope m_relay);
  print_sep ();
  print_endline "=== channel_notification (default-ON) — what Claude Code sees on push path ===";
  let ch = C2c_mcp.channel_notification m_dm in
  let open Yojson.Safe.Util in
  print_endline (ch |> member "params" |> member "content" |> to_string)
