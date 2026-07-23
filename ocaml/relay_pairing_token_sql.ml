open Sqlite3

(* S5a: Pairing token SQL helpers *)

(* B271: use Relay_sqlite_support.with_stmt so pairing paths share the
   process-lifetime statement cache when the relay mutex has activated it.
   Outside that window (tests) the helper falls back to ephemeral finalize. *)
let with_stmt db sql f = Relay_sqlite_support.with_stmt db sql f

let store_pairing_token_db db ~binding_id ~token_b64 ~machine_ed25519_pubkey ~expires_at =
  let sql = "INSERT OR REPLACE INTO pairing_tokens (binding_id, token_b64, machine_ed25519_pubkey, used, expires_at) VALUES (?, ?, ?, 0, ?)" in
  with_stmt db sql (fun stmt ->
    Sqlite3.bind_text stmt 1 binding_id |> ignore;
    Sqlite3.bind_text stmt 2 token_b64 |> ignore;
    Sqlite3.bind_text stmt 3 machine_ed25519_pubkey |> ignore;
    Sqlite3.bind_double stmt 4 expires_at |> ignore;
    let rc = Sqlite3.step stmt in
    if rc = Rc.DONE then Ok ()
    else Error (Printf.sprintf "store_pairing_token failed: %s" (Rc.to_string rc)))

let get_and_burn_pairing_token_db db ~binding_id =
  let now = Unix.gettimeofday () in
  let select_sql = "SELECT token_b64, machine_ed25519_pubkey FROM pairing_tokens WHERE binding_id = ? AND used = 0 AND expires_at > ?" in
  with_stmt db select_sql (fun stmt ->
    Sqlite3.bind_text stmt 1 binding_id |> ignore;
    Sqlite3.bind_double stmt 2 now |> ignore;
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then (
      let token_b64 = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
      let machine_ed25519_pubkey = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
      let update_sql = "UPDATE pairing_tokens SET used = 1 WHERE binding_id = ? AND used = 0" in
      with_stmt db update_sql (fun upd ->
        Sqlite3.bind_text upd 1 binding_id |> ignore;
        Sqlite3.step upd |> ignore);
      Ok (Some (token_b64, machine_ed25519_pubkey))
    ) else if rc = Rc.DONE then
      Ok None
    else
      Error (Printf.sprintf "get_and_burn_pairing_token failed: %s" (Rc.to_string rc)))

let find_pairing_token_db db ~binding_id =
  let now = Unix.gettimeofday () in
  let sql = "SELECT 1 FROM pairing_tokens WHERE binding_id = ? AND used = 0 AND expires_at > ?" in
  with_stmt db sql (fun stmt ->
    Sqlite3.bind_text stmt 1 binding_id |> ignore;
    Sqlite3.bind_double stmt 2 now |> ignore;
    let rc = Sqlite3.step stmt in
    rc = Rc.ROW)
