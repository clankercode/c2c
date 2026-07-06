module NonceCache : sig
  type t
  val create : unit -> t
  val is_seen : t -> phone_pubkey:string -> nonce:string -> bool
  val record : t -> phone_pubkey:string -> nonce:string -> unit
  val cleanup : t -> older_than:float -> int
end = struct
  type t = {
    cache : (string * string, float) Hashtbl.t;
    mutex : Mutex.t;
  }

  let create () = { cache = Hashtbl.create 1024; mutex = Mutex.create (); }

  let is_seen t ~phone_pubkey ~nonce =
    Mutex.lock t.mutex;
    let seen = Hashtbl.mem t.cache (phone_pubkey, nonce) in
    Mutex.unlock t.mutex;
    seen

  let record t ~phone_pubkey ~nonce =
    Mutex.lock t.mutex;
    Hashtbl.replace t.cache (phone_pubkey, nonce) (Unix.gettimeofday ());
    Mutex.unlock t.mutex

  let cleanup t ~older_than =
    Mutex.lock t.mutex;
    let now = Unix.gettimeofday () in
    let to_remove = ref [] in
    Hashtbl.iter
      (fun (pk, nonce) seen_at ->
        if now -. seen_at > older_than then to_remove := (pk, nonce) :: !to_remove)
      t.cache;
    List.iter (fun k -> Hashtbl.remove t.cache k) !to_remove;
    let count = List.length !to_remove in
    Mutex.unlock t.mutex;
    count
end

let nonce_cache = NonceCache.create ()
let is_nonce_seen ~phone_pubkey ~nonce = NonceCache.is_seen nonce_cache ~phone_pubkey ~nonce
let record_nonce ~phone_pubkey ~nonce = NonceCache.record nonce_cache ~phone_pubkey ~nonce
let cleanup_nonce_cache ~older_than = NonceCache.cleanup nonce_cache ~older_than
