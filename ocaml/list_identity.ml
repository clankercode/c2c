(* list_identity.ml — identity kind/scope labeling for the merged peer
   listing (`c2c list --relay`, H6 of the friction-cn reconciliation plan;
   rows A053-A056/A060-A064/A080/A094, backlog B097 gap).

   The merged view shows two DIFFERENT kinds of identifier side by side and
   must label them honestly rather than flattening them into one namespace:

   - a LOCAL identity is a session alias on this machine's broker. Its key
     is the alias (case-insensitive) — broker-scoped, no cryptographic
     anchor required to appear in the listing.
   - a RELAY identity is an alias@host_id relay registration: the alias is
     pinned to a machine identity key and anchored to an opaque host id.

   "Kind" says what an entry IS (local session alias vs relay-anchored
   address); "scope" says where that identity is registered (local-only,
   relay-only, or both). Labeling is descriptive ONLY: it records where an
   entry came from, not how much to trust it. There is deliberately NO
   attestation surface here (no trust tiers, no verified badges, no
   signature checking) — per the friction-cn decision ledger
   (.collab/design/friction-cn-decision-ledger.md, friction-adr0-decision-ledger
   branch), I008 attestation is a separate, unbuilt layer.

   Self-identity match rule: a local registration and a relay lease are the
   SAME identity iff the aliases match case-insensitively AND the lease's
   opaque_host_id equals this machine's host id (the local row's effective
   host). A lease with no opaque_host_id never matches — without a host
   anchor we cannot honestly claim it is this machine. The same alias on a
   DIFFERENT host is a distinct identity and must stay a distinct row,
   disambiguated by the alias@host_id address.

   All functions are pure and total. *)

type scope = Scope_local | Scope_relay | Scope_both

let scope_to_string = function
  | Scope_local -> "local"
  | Scope_relay -> "relay"
  | Scope_both -> "both"

type kind = Kind_local | Kind_relay

let kind_to_string = function
  | Kind_local -> "local"
  | Kind_relay -> "relay"

(* Alias comparisons are case-insensitive everywhere in c2c (Lyra-Quill and
   lyra-quill are the same identity); host ids are lowercase hex already but
   normalise defensively. *)
let norm s = String.lowercase_ascii (String.trim s)

let same_identity ~local_alias ~local_host ~relay_alias ~relay_host =
  match relay_host with
  | None -> false
  | Some rh ->
      norm local_alias = norm relay_alias
      && local_host <> ""
      && norm local_host = norm rh

(* match_merged ~locals ~relays: positional matching between the local rows
   [(alias, effective_host)] and the relay rows [(alias, opaque_host_id
   option)]. Returns:
   - per-local: the index (into [relays]) of the matching relay lease, if
     any — such a local row has scope BOTH and the lease is folded into it;
   - per-relay: whether that lease was merged into some local row (and so
     must not be emitted as its own JSON row).
   If several relay leases match one local row (should not happen — the
   relay keys leases by alias), the first match wins. *)
let match_merged ~(locals : (string * string) list)
    ~(relays : (string * string option) list) : int option list * bool list =
  let relays_arr = Array.of_list relays in
  let merged = Array.make (Array.length relays_arr) false in
  let local_matches =
    List.map
      (fun (local_alias, local_host) ->
        let found = ref None in
        Array.iteri
          (fun i (relay_alias, relay_host) ->
            if !found = None
               && same_identity ~local_alias ~local_host ~relay_alias
                    ~relay_host
            then found := Some i)
          relays_arr;
        (match !found with Some i -> merged.(i) <- true | None -> ());
        !found)
      locals
  in
  (local_matches, Array.to_list merged)

let scope_of_local ~matched = if matched then Scope_both else Scope_local

(* --- `--kind local|relay` filter -------------------------------------------

   Filtering is by where the identity is REGISTERED, so a scope-both row
   (one identity, present on both the local broker and the relay) passes
   BOTH filters:
   - `--kind local`  keeps every local-broker row (scopes local and both);
   - `--kind relay`  keeps relay-registered rows: relay-only rows plus the
     local rows whose identity is also this machine's relay registration
     (scope both). *)

type kind_filter = Kf_local | Kf_relay

let kind_filter_of_string s =
  match norm s with
  | "local" -> Some Kf_local
  | "relay" -> Some Kf_relay
  | _ -> None

let kind_filter_to_string = function Kf_local -> "local" | Kf_relay -> "relay"

let local_passes (kf : kind_filter option) (scope : scope) =
  match kf with
  | None | Some Kf_local -> true
  | Some Kf_relay -> scope = Scope_both

let relay_passes (kf : kind_filter option) =
  match kf with None | Some Kf_relay -> true | Some Kf_local -> false
