(* Unit tests for parse_reaction_content *)
open Alcotest

let parse_ok content expected_ra expected_sid expected_tmid expected_note =
  match C2c_stickers.parse_reaction_content content with
  | None -> failwith "parse_reaction_content returned None"
  | Some (ra, sid, tmid, note) ->
      check string "from" expected_ra ra;
      check string "sticker_id" expected_sid sid;
      check string "target_msg_id" expected_tmid tmid;
      check ( Alcotest.option Alcotest.string ) "note" expected_note note

let parse_fail content =
  match C2c_stickers.parse_reaction_content content with
  | None -> ()
  | Some _ -> failwith "parse_reaction_content should have returned None"

let test_well_formed () =
  parse_ok
    "<c2c event=\"reaction\" from=\"alice\" target_msg_id=\"abc12345\" sticker_id=\"thumbsup\"/>"
    "alice" "thumbsup" "abc12345" None

let test_well_formed_with_note () =
  parse_ok
    "<c2c event=\"reaction\" from=\"bob\" target_msg_id=\"def67890\" sticker_id=\"heart\" note=\"nice\"/>"
    "bob" "heart" "def67890" (Some "nice")

let test_hostile_note_with_angle_brackets () =
  (* Hostile note content including XML-like characters but no embedded quotes *)
  parse_ok
    "<c2c event=\"reaction\" from=\"eve\" target_msg_id=\"xyz00001\" sticker_id=\"fire\" note=\"</c2c> &amp; &lt; &gt;\"/>"
    "eve" "fire" "xyz00001"
    (Some "</c2c> &amp; &lt; &gt;")

let test_scrambled_attr_order () =
  (* Attributes in non-standard order — parser must be order-independent *)
  parse_ok
    "<c2c sticker_id=\"star\" note=\"wow\" from=\"carol\" target_msg_id=\"msg99\" event=\"reaction\"/>"
    "carol" "star" "msg99" (Some "wow")

let test_missing_target_msg_id () =
  (* Valid reaction but missing target_msg_id — should return None *)
  parse_fail
    "<c2c event=\"reaction\" from=\"dave\" sticker_id=\"rain\"/>"

let test_wrong_event () =
  (* event != "reaction" — should return None *)
  parse_fail
    "<c2c event=\"message\" from=\"alice\" target_msg_id=\"abc12345\" sticker_id=\"thumbsup\"/>"

let test_empty_content () =
  parse_fail ""

let test_truncated () =
  parse_fail "<c2c event"

let test_missing_trailing_slash () =
  parse_fail
    "<c2c event=\"reaction\" from=\"alice\" target_msg_id=\"abc12345\" sticker_id=\"thumbsup\">"

let () =
  Alcotest.run "parse_reaction_content"
    [ "reaction_xml", [
        test_case "well-formed reaction"           `Quick test_well_formed;
        test_case "well-formed with note"         `Quick test_well_formed_with_note;
        test_case "hostile note (angle brackets)" `Quick test_hostile_note_with_angle_brackets;
        test_case "scrambled attribute order"      `Quick test_scrambled_attr_order;
        test_case "missing target_msg_id"          `Quick test_missing_target_msg_id;
        test_case "wrong event value"             `Quick test_wrong_event;
        test_case "empty content"                `Quick test_empty_content;
        test_case "truncated"                    `Quick test_truncated;
        test_case "missing trailing slash"        `Quick test_missing_trailing_slash;
      ] ]
