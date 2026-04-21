(* Shared name/alias sanitization used by c2c_start (instance names),
   the MCP broker (aliases/register), and the relay (peer ids).

   Rules: 1..64 chars, [A-Za-z0-9._-], no leading dot. Rejects '/',
   '@', '#', whitespace, and other shell/broker-hostile chars that
   would create nested dirs or collide with alias@repo#host syntax. *)

let is_valid (n : string) : bool =
  let len = String.length n in
  if len = 0 || len > 64 then false
  else if n.[0] = '.' then false
  else begin
    let ok = ref true in
    String.iter (fun c ->
      let good =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '-' || c = '_' || c = '.'
      in
      if not good then ok := false
    ) n;
    !ok
  end

let error_message (kind : string) (n : string) : string =
  Printf.sprintf
    "invalid %s '%s'. Allowed chars: [A-Za-z0-9._-], 1..64, no leading dot."
    kind n
