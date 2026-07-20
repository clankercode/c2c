(** Single-writer ownership for kimi dual-run (P3 C2 / architecture C2).

    Claim-before-POST: exclusive per-message claims under the broker root.
    Both notifier and deliver-service must call [try_claim] before REST POST. *)

type claim_result =
  | Claimed
  | Busy of { holder : string option; expires_at : float }

val default_ttl_s : unit -> float
(** Default claim TTL (30s unless [C2C_KIMI_DELIVERY_CLAIM_TTL] set). *)

val message_key : from_alias:string -> ts:float -> content:string -> string
(** Stable 12-hex message key (shared with notifier notification id inputs). *)

val message_key_of_msg : C2c_mcp.message -> string

val claims_dir : broker_root:string -> string

val claim_path :
  broker_root:string -> session_id:string -> msg_key:string -> string

val try_claim :
  broker_root:string
  -> session_id:string
  -> msg_key:string
  -> claimant:string
  -> ?ttl_s:float
  -> unit
  -> claim_result

val release :
  broker_root:string
  -> session_id:string
  -> msg_key:string
  -> claimant:string
  -> unit
(** Release if [claimant] holds the claim. Total (no-op otherwise). *)
