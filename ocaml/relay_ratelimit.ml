(* Rate limiter for M1 relay endpoints.
   Token-bucket algorithm: each key has a bucket that refills at a constant rate.
   Allows bursts up to [capacity] but enforces average [refill_rate]. *)

module type RATE_LIMIT_POLICY = sig
  type t
  val make : unit -> t
  val check : t -> key:string -> cost:int -> [> `Allow | `Deny of float ]
  (* `Allow: proceed; `Deny retry_after_seconds: slow down caller *)
  val cleanup : t -> older_than:float -> int
  (* removes entries unused for [older_than] seconds. returns count removed *)
end

module TokenBucket : sig
  type t
  val create : capacity:float -> refill_rate:float -> t
  val allow : t -> cost:int -> [> `Allow | `Deny of float ]
  (* consumes [cost] tokens. returns `Allow if enough, `Deny (secs_to_wait) otherwise *)
  val touch : t -> unit
  (* called on successful auth — updates last_seen *)
  val tokens : t -> float
  val last_seen : t -> float
end = struct
  type t = {
    mutable tokens : float;
    refill_rate : float;  (* tokens per second *)
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

(* Per-endpoint policies. Values are (capacity, refill_rate per second). *)
let policy_of_endpoint path =
  if        String.length path >= 7 && String.sub path 0 7 = "/pubkey" then
    Some (100.0, 10.0)  (* generous: allow burst of 100, refill 10/s *)
  else if   String.length path >= 12 && String.sub path 0 12 = "/mobile-pair" then
    Some (10.0, 0.167)   (* strict: 10/min ≈ 0.167/s *)
  else if  String.length path >= 12 && String.sub path 0 12 = "/device-pair" then
    Some (10.0, 0.167)   (* strict: 10/min, per user-code *)
  else if  String.length path >= 10 && String.sub path 0 10 = "/observer/" then
    Some (20.0, 0.333)   (* strict: 20/min ≈ 0.333/s *)
  else
    None

module Make (P : sig end) = struct
  type policy_spec = { capacity : float; refill_rate : float }

  type t = {
    mutable buckets : (string, TokenBucket.t * policy_spec) Hashtbl.t;
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
    | None -> `Allow  (* no policy = no limiting *)
    | Some (capacity, refill_rate) ->
      with_lock t (fun () ->
        let now = Unix.gettimeofday () in
        match Hashtbl.find_opt t.buckets key with
        | Some (bucket, spec) ->
          let result = TokenBucket.allow bucket ~cost in
          (match result with
           | `Allow -> TokenBucket.touch bucket
           | `Deny _ -> ());
          result
        | None ->
          let bucket = TokenBucket.create ~capacity ~refill_rate in
          Hashtbl.add t.buckets key (bucket, { capacity; refill_rate });
          TokenBucket.allow bucket ~cost
      )

  let cleanup t ~older_than =
    with_lock t (fun () ->
      let now = Unix.gettimeofday () in
      let to_remove = ref [] in
      Hashtbl.iter (fun key (bucket, _spec) ->
        if now -. TokenBucket.last_seen bucket > older_than then
          to_remove := key :: !to_remove
      ) t.buckets;
      List.iter (fun k -> Hashtbl.remove t.buckets k) !to_remove;
      List.length !to_remove
    )
end
