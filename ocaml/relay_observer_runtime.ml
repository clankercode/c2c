module ObserverBindings = Relay_observer_bindings.ObserverBindings

let observer_bindings = ObserverBindings.create ()

let get_observer_binding ~binding_id =
  ObserverBindings.get observer_bindings ~binding_id

let add_observer_binding ~binding_id ~phone_ed25519_pubkey ~phone_x25519_pubkey
    ~machine_ed25519_pubkey ~provenance_sig =
  ObserverBindings.add observer_bindings ~binding_id ~phone_ed25519_pubkey
    ~phone_x25519_pubkey ~machine_ed25519_pubkey ~provenance_sig

let binding_id_of_phone_pk ~phone_ed25519_pubkey =
  ObserverBindings.binding_id_of_phone_pk observer_bindings ~phone_ed25519_pubkey

(* S6: Short queue for observer message short-term storage *)
let short_queue = Relay_short_queue.ShortQueue.create ()
