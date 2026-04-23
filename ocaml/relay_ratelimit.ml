(* Rate limiter for M1 relay endpoints.
   Token-bucket algorithm: each key has a bucket that refills at a constant rate.
   Allows bursts up to [capacity] but enforces average [refill_rate].
   Emits structured JSON logs for pair/unpair/handshake events per spec S4b. *)

module TokenBucket : sig
  type t
  val create : capacity:float -> refill_rate:float -> t
  val allow : t -> cost:int -> [> `Allow | `Deny of float ]
  val touch : t -> unit
  val tokens : t -> float
  val last_seen : t -> float
end = struct
  type t = {
    mutable tokens : float;
    refill_rate : float;
    capacity : float;
    mutable last_seen : float;
  }

  let create ~capacity ~refill_rate =
    let now = Unix.gettimeofday () in
    { tokens = capacity; refill_rate; capacity; last_seen = now }

  let refill t =
    let now = Unix.gettimeofday () in
    let elapsed = now -. t.last_seen in
    let added = elapsed *. t.refill_rate in
    t.tokens <- min t.capacity (t.tokens +. added);
    t.last_seen <- now

  let allow t ~cost =
    refill t;
    let needed = float_of_int cost in
    if t.tokens >= needed then begin
      t.tokens <- t.tokens -. needed;
      `Allow
    end else begin
      let deficit = needed -. t.tokens in
      let secs_to_wait = deficit /. t.refill_rate in
      `Deny secs_to_wait
    end

  let touch t =
    let now = Unix.gettimeofday () in
    t.last_seen <- now

  let tokens t = t.tokens
  let last_seen t = t.last_seen
end

(* 8-char prefix helper — safe on strings shorter than 8 chars. *)
let prefix8 s =
  if String.length s >= 8 then String.sub s 0 8 else s

(* Per-endpoint policies. Values are (capacity, refill_rate per second). *)
let policy_of_endpoint path =
  let starts_with prefix s =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  in
  if starts_with "/pubkey" path then
    Some (100.0, 10.0)  (* generous: burst 100, refill 10/s *)
  else if starts_with "/mobile-pair" path then
    Some (10.0, 0.167)   (* strict: 10/min ≈ 0.167/s *)
  else if starts_with "/device-pair" path then
    Some (5.0, 0.083)   (* strict: 5/min ≈ 0.083/s *)
  else if starts_with "/observer" path then
    Some (20.0, 0.333)  (* strict: 20/min ≈ 0.333/s *)
  else
    None

(* Structured log emitter for S4b pair/handshake events.
   All identifiers are 8-char prefixes to correlate without leaking full IDs. *)
let structured_log ~event ?(binding_id_prefix="") ?(phone_pubkey_prefix="")
    ~source_ip_prefix ~result ?(reason="") () =
  let ts = Unix.gettimeofday () in
  let reason = if String.length reason > 120 then String.sub reason 0 120 else reason in
  let fields = [
    "event", `String event;
    "ts", `Float ts;
    "binding_id_prefix", `String (prefix8 binding_id_prefix);
    "phone_pubkey_prefix", `String (prefix8 phone_pubkey_prefix);
    "source_ip_prefix", `String (prefix8 source_ip_prefix);
    "result", `String result;
  ] in
  let fields = if reason <> "" then ("reason", `String reason) :: fields else fields in
  Logs.info (fun m -> m "%s" (Yojson.Safe.to_string (`Assoc fields)))

module Make () = struct
  type t = {
    mutable buckets : (string, TokenBucket.t) Hashtbl.t;
    mutex : Mutex.t;
    gc_interval : float;
  }

  let create ?(gc_interval=300.0) () =
    { buckets = Hashtbl.create 64; mutex = Mutex.create (); gc_interval }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let check t ~(key:string) ~(cost:int) ~(path:string) : [> `Allow | `Deny of float ] =
    match policy_of_endpoint path with
    | None -> `Allow
    | Some (capacity, refill_rate) ->
        with_lock t (fun () ->
          match Hashtbl.find_opt t.buckets key with
          | Some bucket ->
              let result = TokenBucket.allow bucket ~cost in
              (match result with
               | `Allow -> TokenBucket.touch bucket
               | `Deny _ -> ());
              result
          | None ->
              let bucket = TokenBucket.create ~capacity ~refill_rate in
              Hashtbl.add t.buckets key bucket;
              TokenBucket.allow bucket ~cost
        )

  (* Composite-key check for /device-pair: rate-limit by IP + user-code.
     [extra_id] is the user-code extracted by the route handler. *)
  let check_composite t ~(key:string) ~(extra_id:string) ~(cost:int) ~(path:string) =
    check t ~key:(key ^ "|" ^ extra_id) ~cost ~path

  let cleanup t ~older_than =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let to_remove = ref [] in
      Hashtbl.iter (fun key bucket ->
        if now -. TokenBucket.last_seen bucket > older_than then
          to_remove := key :: !to_remove
      ) t.buckets;
      List.iter (fun k -> Hashtbl.remove t.buckets k) !to_remove;
      List.length !to_remove
    )
end
