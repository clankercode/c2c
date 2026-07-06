(* S6: Observer session table - binding_id -> list of active WebSocket sessions *)

module ObserverSessions : sig
  type t
  val create : unit -> t
  val register : t -> binding_id:string -> Relay_ws_frame.Session.t -> unit
  val remove : t -> binding_id:string -> Relay_ws_frame.Session.t -> unit
  val get : t -> binding_id:string -> Relay_ws_frame.Session.t list
end = struct
  type t = {
    mutable sessions : (string, Relay_ws_frame.Session.t list) Hashtbl.t;
    mutex : Mutex.t;
  }
  let create () = {
    sessions = Hashtbl.create 64;
    mutex = Mutex.create ();
  }
  let register t ~binding_id session =
    Mutex.lock t.mutex;
    begin try
      let existing = try Hashtbl.find t.sessions binding_id with Not_found -> [] in
      Hashtbl.replace t.sessions binding_id (session :: existing)
    with e -> Mutex.unlock t.mutex; raise e end;
    Mutex.unlock t.mutex
  let remove t ~binding_id session =
    Mutex.lock t.mutex;
    begin try
      let existing = try Hashtbl.find t.sessions binding_id with Not_found -> [] in
      let filtered = List.filter (fun s -> s <> session) existing in
      if filtered = [] then Hashtbl.remove t.sessions binding_id
      else Hashtbl.replace t.sessions binding_id filtered
    with e -> Mutex.unlock t.mutex; raise e end;
    Mutex.unlock t.mutex
  let get t ~binding_id =
    Mutex.lock t.mutex;
    let result = try Hashtbl.find t.sessions binding_id with Not_found -> [] in
    Mutex.unlock t.mutex;
    result
end
