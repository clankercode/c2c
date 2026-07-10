(* List_identity — identity kind/scope labeling for the merged peer listing
   (`c2c list --relay`, H6). Pure and total; see list_identity.ml for the
   identity model and the self-identity match rule.

   Kind = what an entry IS: a local session alias (broker-scoped) or a
   relay-anchored alias@host_id address. Scope = where that identity is
   registered: local-only, relay-only, or both. Descriptive labels only —
   deliberately NO attestation (no trust tiers / verified badges); see the
   friction-cn decision ledger (.collab/design/friction-cn-decision-ledger.md
   on the friction-adr0-decision-ledger branch). *)

type scope = Scope_local | Scope_relay | Scope_both

val scope_to_string : scope -> string
(** "local" | "relay" | "both" — the JSON [identity_scope] contract. *)

type kind = Kind_local | Kind_relay

val kind_to_string : kind -> string
(** "local" | "relay" — the JSON [identity_kind] contract. *)

val same_identity :
  local_alias:string ->
  local_host:string ->
  relay_alias:string ->
  relay_host:string option ->
  bool
(** Self-identity match rule: aliases equal case-insensitively AND the relay
    lease's opaque_host_id equals the local row's effective host id. A lease
    without an opaque_host_id ([relay_host = None]) never matches. *)

val match_merged :
  locals:(string * string) list ->
  relays:(string * string option) list ->
  int option list * bool list
(** [match_merged ~locals ~relays] over local [(alias, effective_host)] rows
    and relay [(alias, opaque_host_id option)] rows. Returns, positionally:
    per-local the index of the matching relay lease (scope both; lease is
    folded into the local row), and per-relay whether it was merged into a
    local row (and so is not emitted as its own row). *)

val scope_of_local : matched:bool -> scope

type kind_filter = Kf_local | Kf_relay

val kind_filter_of_string : string -> kind_filter option
val kind_filter_to_string : kind_filter -> string

val local_passes : kind_filter option -> scope -> bool
(** [--kind local] keeps every local row; [--kind relay] keeps only local
    rows with scope both (identity also registered on the relay). *)

val relay_passes : kind_filter option -> bool
(** Relay-only rows pass unless the filter is [--kind local]. *)
