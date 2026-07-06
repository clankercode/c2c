(* #379: split "alias@host" into (alias, Some host) or (s, None) if no @. *)
let split_alias_host s =
  match String.index_opt s '@' with
  | None -> (s, None)
  | Some i ->
    (String.sub s 0 i,
     Some (String.sub s (i + 1) (String.length s - i - 1)))

(* #379: is the host part acceptable?
   None = no host in to_alias -> always ok
   Some "" | Some "relay" -> always ok (back-compat with test fixtures)
   Some h -> ok only if h = self_host *)
let host_acceptable ~self_host = function
  | None -> true
  | Some "" | Some "relay" -> true
  | Some h -> (match self_host with Some sh -> h = sh | None -> false)

(* #330: a peer relay known to this relay, for cross-relay forwarding. *)
type peer_relay_t = {
  name : string;        (* well-known name, e.g. "relay-b" *)
  url : string;        (* https://relay-b:9001 *)
  identity_pk : string; (* Ed25519 pubkey of that relay, for auth *)
}
