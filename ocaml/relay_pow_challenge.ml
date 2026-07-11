let pow_challenge_ttl_s = 120
let pow_header_name = "X-C2C-PoW-Next"
let relay_pow_policy = Pow_policy.create ()

type pow_challenge = {
  difficulty : int;
  epoch : int;
  server_nonce : string;
  ttl_s : int;
}

let relay_pow_enabled () =
  match Sys.getenv_opt "C2C_RELAY_POW" with
  | Some "1" -> true
  | _ -> false

module PowChallenges : sig
  val issue :
    route:string -> actor_id:string -> difficulty:int -> now:float ->
    pow_challenge
  val consume_if_valid :
    route:string -> actor_id:string -> epoch:int -> server_nonce:string ->
    now:float -> bool
end = struct
  type key = string * string * int * string

  type t = {
    issued : (key, float) Hashtbl.t;
    mutex : Mutex.t;
  }

  let state = { issued = Hashtbl.create 256; mutex = Mutex.create () }

  let key ~route ~actor_id ~epoch ~server_nonce =
    (route, actor_id, epoch, server_nonce)

  let cleanup_locked ~now =
    let expired = ref [] in
    Hashtbl.iter
      (fun key expires_at ->
         if expires_at <= now then expired := key :: !expired)
      state.issued;
    List.iter (Hashtbl.remove state.issued) !expired

  let issue ~route ~actor_id ~difficulty ~now =
    let epoch =
      int_of_float (floor (now /. float_of_int pow_challenge_ttl_s))
    in
    let server_nonce = Relay_signed_ops.random_nonce_b64 () in
    let expires_at = now +. float_of_int pow_challenge_ttl_s in
    Mutex.lock state.mutex;
    begin
      try
        cleanup_locked ~now;
        Hashtbl.replace state.issued
          (key ~route ~actor_id ~epoch ~server_nonce)
          expires_at
      with exn ->
        Mutex.unlock state.mutex;
        raise exn
    end;
    Mutex.unlock state.mutex;
    { difficulty; epoch; server_nonce; ttl_s = pow_challenge_ttl_s }

  let consume_if_valid ~route ~actor_id ~epoch ~server_nonce ~now =
    Mutex.lock state.mutex;
    let consumed =
      try
        cleanup_locked ~now;
        let k = key ~route ~actor_id ~epoch ~server_nonce in
        match Hashtbl.find_opt state.issued k with
        | Some expires_at when expires_at > now ->
          Hashtbl.remove state.issued k;
          true
        | _ -> false
      with exn ->
        Mutex.unlock state.mutex;
        raise exn
    in
    Mutex.unlock state.mutex;
    consumed
end

let stateless_pow_challenge ~difficulty ~now =
  let epoch =
    int_of_float (floor (now /. float_of_int pow_challenge_ttl_s))
  in
  let server_nonce = Relay_signed_ops.random_nonce_b64 () in
  { difficulty; epoch; server_nonce; ttl_s = pow_challenge_ttl_s }

let issue_pow_challenge ~route ~actor_id ~difficulty =
  let now = Unix.gettimeofday () in
  if difficulty > 0 then
    PowChallenges.issue ~route ~actor_id ~difficulty ~now
  else
    stateless_pow_challenge ~difficulty ~now

let pow_header_value challenge =
  Printf.sprintf "difficulty=%d; epoch=%d; server_nonce=%s; ttl=%d"
    challenge.difficulty challenge.epoch challenge.server_nonce challenge.ttl_s

let pow_header challenge = (pow_header_name, pow_header_value challenge)

(* B014: per-message PoW-difficulty metadata for delivered relay messages.
   The scheme is sha256-leading-zeros-v1, so a difficulty of [d] leading-zero
   bits costs a sender ~2^d hashes in expectation to mint. We surface both the
   raw bit-count and the interpretable "expected hashes" weight so a recipient
   agent can reason about how much work a sender's request represented without
   knowing the PoW internals. Storage keeps only the int bit-count; the rich
   object is derived at every JSON emission boundary. *)
let pow_scheme = Pow.scheme_id

let expected_hashes_of_difficulty difficulty =
  if difficulty <= 0 then 0
  else if difficulty >= 62 then max_int (* far beyond d_max; avoid overflow *)
  else 1 lsl difficulty

(* Sentinel stored when difficulty was not recorded (relay PoW disabled or the
   sender's identity pubkey could not be resolved). Rows carrying it emit no
   [pow] object. *)
let pow_difficulty_unrecorded = -1

let pow_meta_json ~difficulty =
  `Assoc [
    ("difficulty_bits", `Int difficulty);
    ("expected_hashes", `Int (expected_hashes_of_difficulty difficulty));
    ("scheme", `String pow_scheme);
  ]

(* Attach a [pow] object to a message's JSON field list when [difficulty] was
   recorded (>= 0). Additive and outside any signed [content] field, so
   signatures/encryption are unaffected (B014 constraint). *)
let with_pow_meta ~difficulty fields =
  if difficulty < 0 then fields
  else fields @ [ ("pow", pow_meta_json ~difficulty) ]
