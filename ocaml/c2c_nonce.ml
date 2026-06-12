(* 4-character lowercase alphanumeric nonce suffix for auto-generated aliases.
   Mixed-case aliases create surprising identity collisions because the broker
   compares aliases case-insensitively, so the nonce charset is lowercase-only. *)

let () = Random.self_init ()

let charset = "0123456789abcdefghijklmnopqrstuvwxyz"

let gen_nonce () =
  String.init 4 (fun _ -> charset.[Random.int 36])

let append_nonce ?(no_nonce = false) name =
  if no_nonce then name
  else Printf.sprintf "%s-%s" name (gen_nonce ())
