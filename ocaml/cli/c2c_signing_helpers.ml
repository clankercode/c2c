(* c2c_signing_helpers.ml — shared per-alias signing key helpers for peer-pass and stickers *)

open C2c_utils

let per_alias_key_path ~alias =
  Some (C2c_utils.resolve_broker_root () // "keys" // (alias ^ ".ed25519"))
