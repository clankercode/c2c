(* C2c_kimi_delivery_claim — single-writer ownership for kimi dual-run (P3 C2).

   Claim-before-POST: per-message exclusive claim under the broker root.
   Both the per-alias notifier and deliver-service call [try_claim] before
   REST POST. Loser skips the message and leaves it in the inbox.

   Locked decisions (architecture grill 2026-07-20):
   - per-message keys (stable digest of from|ts|content)
   - broker-local store: <broker_root>/.kimi-delivery-claims/
   - default TTL 30s (C2C_KIMI_DELIVERY_CLAIM_TTL override)
   - fail → skip / leave inbox (no busy-wait, no drop-without-POST)
*)

let ( // ) = Filename.concat

type claim_result =
  | Claimed
  | Busy of { holder : string option; expires_at : float }

let default_ttl_s () =
  match Sys.getenv_opt "C2C_KIMI_DELIVERY_CLAIM_TTL" with
  | Some s ->
      (try
         let f = float_of_string (String.trim s) in
         if f < 1. then 1. else if f > 600. then 600. else f
       with _ -> 30.)
  | None -> 30.

(** Stable per-message key (12 hex chars). Same inputs as
    [C2c_kimi_notifier.notification_id_for_msg] so dual paths agree. *)
let message_key ~from_alias ~ts ~content =
  let key = Printf.sprintf "%s|%.6f|%s" from_alias ts content in
  let digest = Digest.to_hex (Digest.string key) in
  String.sub digest 0 12

let message_key_of_msg (msg : C2c_mcp.message) =
  message_key ~from_alias:msg.from_alias ~ts:msg.ts ~content:msg.content

let claims_dir ~broker_root = broker_root // ".kimi-delivery-claims"

let claim_path ~broker_root ~session_id ~msg_key =
  (* session_id isolates inboxes that share a broker; msg_key is the message. *)
  let safe_sid =
    String.map
      (function
        | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_') as c -> c
        | _ -> '_')
      session_id
  in
  claims_dir ~broker_root // (safe_sid ^ "__" ^ msg_key ^ ".claim")

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_claim_file path ~claimant ~expires_at =
  let oc = open_out_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      Printf.fprintf oc "claimant=%s\nexpires_at=%.6f\n" claimant expires_at;
      flush oc;
      (try Unix.fsync (Unix.descr_of_out_channel oc) with _ -> ()))

let parse_claim_file path =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let claimant = ref None in
        let expires = ref None in
        (try
           while true do
             let line = input_line ic in
             match String.split_on_char '=' line with
             | "claimant" :: rest ->
                 claimant := Some (String.concat "=" rest |> String.trim)
             | "expires_at" :: [ v ] ->
                 (try expires := Some (float_of_string (String.trim v))
                  with _ -> ())
             | _ -> ()
           done
         with End_of_file -> ());
        match !expires with
        | Some exp -> Some (!claimant, exp)
        | None -> None)
  with _ -> None

let now () = Unix.gettimeofday ()

(** [try_claim ~broker_root ~session_id ~msg_key ~claimant ?ttl_s ()].
    Returns [Claimed] if this claimant holds the exclusive claim, or [Busy]
    if another live claim exists. Expired claims are reclaimed. *)
let try_claim ~broker_root ~session_id ~msg_key ~claimant
    ?(ttl_s = default_ttl_s ()) () =
  let dir = claims_dir ~broker_root in
  mkdir_p dir;
  let path = claim_path ~broker_root ~session_id ~msg_key in
  let expires_at = now () +. ttl_s in
  let rec attempt retries =
    try
      write_claim_file path ~claimant ~expires_at;
      Claimed
    with Sys_error _ | Unix.Unix_error (Unix.EEXIST, _, _) ->
      (match parse_claim_file path with
       | Some (holder, exp) when exp > now () ->
           if holder = Some claimant then Claimed
           else Busy { holder; expires_at = exp }
       | _ ->
           (* Expired or corrupt — remove and retry once. *)
           (try Unix.unlink path with _ -> ());
           if retries > 0 then attempt (retries - 1)
           else Busy { holder = None; expires_at = now () })
  in
  attempt 2

let release ~broker_root ~session_id ~msg_key ~claimant =
  let path = claim_path ~broker_root ~session_id ~msg_key in
  match parse_claim_file path with
  | Some (Some h, _) when h = claimant ->
      (try Unix.unlink path with _ -> ())
  | Some (None, _) -> (try Unix.unlink path with _ -> ())
  | _ -> ()
  (* Not ours or missing — no-op (total). *)
