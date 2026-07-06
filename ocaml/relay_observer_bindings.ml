(* --- S4/S5a: Observer bindings --- *)

module ObserverBindings : sig
  type t
  val create : unit -> t
  val add : t -> binding_id:string -> phone_ed25519_pubkey:string -> phone_x25519_pubkey:string -> machine_ed25519_pubkey:string -> provenance_sig:string -> unit
  val get : t -> binding_id:string -> (string * string * string * string) option
  (** Returns (phone_ed25519_pubkey, phone_x25519_pubkey, machine_ed25519_pubkey, provenance_sig).
      provenance_sig is the original token sig used to authorize the binding. *)
  val binding_id_of_phone_pk : t -> phone_ed25519_pubkey:string -> string option
  val remove : t -> binding_id:string -> unit
end = struct
  type binding = {
    phone_ed25519_pubkey : string;
    phone_x25519_pubkey : string;
    machine_ed25519_pubkey : string;
    provenance_sig : string;
    issued_at : float;
  }
  type t = {
    bindings : (string, binding) Hashtbl.t;
    phone_pk_to_binding : (string, string) Hashtbl.t;
    mutex : Mutex.t;
  }
  let create () = {
    bindings = Hashtbl.create 64;
    phone_pk_to_binding = Hashtbl.create 64;
    mutex = Mutex.create ();
  }
  let add t ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey ~machine_ed25519_pubkey ~provenance_sig =
    Mutex.lock t.mutex;
    Hashtbl.replace t.bindings binding_id {
      phone_ed25519_pubkey; phone_x25519_pubkey;
      machine_ed25519_pubkey; provenance_sig;
      issued_at = Unix.gettimeofday ();
    };
    Hashtbl.replace t.phone_pk_to_binding phone_ed25519_pubkey binding_id;
    Mutex.unlock t.mutex
  let get t ~binding_id =
    Mutex.lock t.mutex;
    let result = Hashtbl.find_opt t.bindings binding_id in
    Mutex.unlock t.mutex;
    match result with
    | Some b -> Some (b.phone_ed25519_pubkey, b.phone_x25519_pubkey, b.machine_ed25519_pubkey, b.provenance_sig)
    | None -> None
  let binding_id_of_phone_pk t ~phone_ed25519_pubkey =
    Mutex.lock t.mutex;
    let result = Hashtbl.find_opt t.phone_pk_to_binding phone_ed25519_pubkey in
    Mutex.unlock t.mutex;
    result
  let remove t ~binding_id =
    Mutex.lock t.mutex;
    (match Hashtbl.find_opt t.bindings binding_id with
     | Some b -> Hashtbl.remove t.phone_pk_to_binding b.phone_ed25519_pubkey
     | None -> ());
    Hashtbl.remove t.bindings binding_id;
    Mutex.unlock t.mutex
end
