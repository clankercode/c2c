(* ShortQueue: In-memory ring buffer for observer message short-term storage.
   Per-binding queues, max 1000 messages or 1 hour TTL (whichever first).
   Spec: M1-breakdown.md §S6 *)

type message = {
  ts : float;
  from_alias : string;
  to_alias : string;
  room_id : string option;
  content : string;
}

module ShortQueue : sig
  type t
  val create : unit -> t
  val push : t -> binding_id:string -> message -> unit
  val get_after : t -> binding_id:string -> since_ts:float -> message list
  val oldest_ts : t -> binding_id:string -> float option
  val cleanup : t -> older_than:float -> int
  val clear : t -> binding_id:string -> unit
end = struct

  type ring = {
    msgs : message array;
    mutable head : int;
    mutable count : int;
  }

  let max_size = 1000

  let create_ring () = {
    msgs = Array.make max_size {
      ts = 0.0;
      from_alias = "";
      to_alias = "";
      room_id = None;
      content = "";
    };
    head = 0;
    count = 0;
  }

  let ring_push (r : ring) (msg : message) =
    r.msgs.(r.head) <- msg;
    r.head <- (r.head + 1) mod max_size;
    if r.count < max_size then r.count <- r.count + 1

  let ring_to_list (r : ring) : message list =
    if r.count = 0 then []
    else if r.count < max_size then
      let rec loop i acc =
        if i >= r.count then List.rev acc
        else loop (i + 1) (r.msgs.(i) :: acc)
      in
      loop 0 []
    else
      let start = r.head in
      let rec loop i acc =
        if i = start then List.rev acc
        else
          let idx = if i < 0 then max_size + i + 1 else i in
          loop (i - 1) (r.msgs.(idx) :: acc)
      in
      loop (start - 1) []

  type t = {
    mutable rings : (string, ring) Hashtbl.t;
    mutable oldest_timestamps : (string, float) Hashtbl.t;
    mutex : Mutex.t;
  }

  let create () = {
    rings = Hashtbl.create 64;
    oldest_timestamps = Hashtbl.create 64;
    mutex = Mutex.create ();
  }

  let get_ring (t : t) ~binding_id =
    match Hashtbl.find_opt t.rings binding_id with
    | Some r -> r
    | None ->
      let r = create_ring () in
      Hashtbl.add t.rings binding_id r;
      r

  let push t ~binding_id (msg : message) =
    Mutex.lock t.mutex;
    begin try
      let r = get_ring t ~binding_id in
      ring_push r msg;
      (match Hashtbl.find_opt t.oldest_timestamps binding_id with
       | None ->
         Hashtbl.replace t.oldest_timestamps binding_id msg.ts
       | Some oldest ->
         if msg.ts < oldest then
           Hashtbl.replace t.oldest_timestamps binding_id msg.ts)
    with e ->
      Mutex.unlock t.mutex;
      raise e
    end;
    Mutex.unlock t.mutex

  let get_after t ~binding_id ~since_ts =
    (* No lock needed for read - the list is immutable *)
    match Hashtbl.find_opt t.rings binding_id with
    | None -> []
    | Some r ->
      let all_msgs = ring_to_list r in
      List.filter (fun msg -> msg.ts > since_ts) all_msgs

  let oldest_ts t ~binding_id =
    Hashtbl.find_opt t.oldest_timestamps binding_id

  let cleanup t ~older_than =
    Mutex.lock t.mutex;
    let count = ref 0 in
    begin try
      Hashtbl.iter (fun binding_id r ->
        let old_msgs, new_msgs =
          List.partition (fun msg -> msg.ts < older_than) (ring_to_list r)
        in
        count := !count + List.length old_msgs;
        let new_ring = create_ring () in
        List.iter (fun msg -> ring_push new_ring msg) (List.rev new_msgs);
        Hashtbl.replace t.rings binding_id new_ring;
        match new_msgs with
        | [] -> Hashtbl.remove t.oldest_timestamps binding_id
        | _ ->
          let oldest = List.fold_left (fun acc msg -> min acc msg.ts) max_float new_msgs in
          Hashtbl.replace t.oldest_timestamps binding_id oldest
      ) t.rings
    with e ->
      Mutex.unlock t.mutex;
      raise e
    end;
    Mutex.unlock t.mutex;
    !count

  let clear t ~binding_id =
    Mutex.lock t.mutex;
    begin try
      Hashtbl.remove t.rings binding_id;
      Hashtbl.remove t.oldest_timestamps binding_id
    with e ->
      Mutex.unlock t.mutex;
      raise e
    end;
    Mutex.unlock t.mutex
end