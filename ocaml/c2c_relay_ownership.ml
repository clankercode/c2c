(** See {!C2c_relay_ownership}. *)

type lease = {
  alias : string;
  host_id : string;
  session_id : string;
}

type intent = {
  lease : lease;
  eligible : bool;
}

type observed = {
  lease : lease;
  expires_at : float;
  public : bool;
}

type action =
  | Publish
  | Renew
  | Stop_renewal
  | Wait_for_connector
  | Keep
  | Refuse_foreign

type plan = {
  actions : action list;
  reason : string;
}

type claim_error = Foreign_owner of lease

type registry = {
  owners : (string, lease) Hashtbl.t;
}

let make_lease ~alias ~host_id ~session_id =
  { alias = String.trim alias; host_id = String.trim host_id;
    session_id = String.trim session_id }

let remote_address lease = lease.alias ^ "@" ^ lease.host_id

let same_owner a b =
  String.equal (String.lowercase_ascii a.alias) (String.lowercase_ascii b.alias)
  && String.equal a.host_id b.host_id
  && String.equal a.session_id b.session_id

(* Relay aliases are case-insensitive, and one relay lease row exists per
   normalized alias. Keeping the key alias-only prevents a second service from
   attempting to own the same remote row under a different host/session tuple. *)
let owner_key lease = String.lowercase_ascii lease.alias

let create_registry () = { owners = Hashtbl.create 16 }

let claim registry lease =
  let key = owner_key lease in
  match Hashtbl.find_opt registry.owners key with
  | None ->
      Hashtbl.replace registry.owners key lease;
      Ok ()
  | Some current when same_owner current lease -> Ok ()
  | Some current -> Error (Foreign_owner current)

let release registry lease =
  let key = owner_key lease in
  match Hashtbl.find_opt registry.owners key with
  | Some current when same_owner current lease ->
      Hashtbl.remove registry.owners key;
      true
  | _ -> false

let owner registry ~alias = Hashtbl.find_opt registry.owners (String.lowercase_ascii alias)

let plan ~relay_enabled ~now ~renew_before_s intent observed =
  if not relay_enabled then
    (match intent, observed with
     | Some ({ lease; _ } : intent), Some (current : observed)
       when same_owner lease current.lease ->
         { actions = [ Stop_renewal ];
           reason = "relay disabled; stop renewal and keep local delivery authoritative" }
     | _ ->
         { actions = [ Keep ]; reason = "relay disabled; local delivery remains authoritative" })
  else
    match intent with
    | None ->
        { actions = [ Keep ]; reason = "no service-owned advertisement intent" }
    | Some ({ lease; eligible = false } : intent) ->
        (match observed with
         | Some current when same_owner lease current.lease ->
             { actions = [ Stop_renewal ];
               reason = "service alias retired; wait for relay TTL expiry" }
         | Some _ ->
             { actions = [ Refuse_foreign ];
               reason = "refusing to retire a foreign relay lease" }
         | None ->
             { actions = [ Keep ]; reason = "service alias retired and no lease is observed" })
    | Some ({ lease; eligible = true } : intent) ->
        (match observed with
         | None ->
             { actions = [ Wait_for_connector ];
               reason = "machine relay connector has not established the lease" }
         | Some current when not (same_owner lease current.lease) ->
             { actions = [ Refuse_foreign ];
               reason = "foreign relay lease owns this alias" }
         | Some current ->
             let renew_due =
               not (Float.is_finite current.expires_at)
               || current.expires_at <= now +. Float.max 0. renew_before_s
             in
             if current.public then
               if renew_due then
                 { actions = [ Renew ]; reason = "owned advertisement renewal is due" }
               else
                 { actions = [ Keep ]; reason = "owned advertisement is current" }
             else if renew_due then
               { actions = [ Renew; Publish ];
                 reason = "owned lease needs renewal and publication" }
             else
               { actions = [ Publish ];
                 reason = "owned lease is private; publish explicit service intent" })

let retry_delay_s ~base_s ~max_s ~attempt =
  let base = if Float.is_finite base_s && base_s > 0. then base_s else 1. in
  let cap = if Float.is_finite max_s && max_s > 0. then max_s else base in
  let attempt = max 0 attempt in
  let multiplier = 2. ** float_of_int (min attempt 30) in
  Float.min cap (base *. multiplier)

let action_to_string = function
  | Publish -> "publish"
  | Renew -> "renew"
  | Stop_renewal -> "stop-renewal"
  | Wait_for_connector -> "wait-for-connector"
  | Keep -> "keep"
  | Refuse_foreign -> "refuse-foreign"
