(* C2c_delivery_endpoint — hybrid DeliveryEndpoint seam (P3 C1).

   Module type + registry for push delivery. First real adapter: kimi REST.
   Mode_* in deliver_inbox remains for legacy fd/inotify/wake_inject arms until
   ≥2 real adapters justify deleting the fan-out (architecture grill).

   drain_policy: adapter declares who rewrites the inbox after push.
*)

type probe_result =
  [ `Live
  | `Dead of string
  | `Unknown
  ]

type drain_policy =
  | After_push
  | Hooks_own_drain
  | Never

type endpoint = {
  kind : string;
  broker_root : string;
  session_id : string;
  alias : string;
  workdir : string option;
}

module type S = sig
  val kind : string
  val probe : endpoint -> probe_result
  val deliver : endpoint -> C2c_mcp.message -> (unit, string) result
  val drain_policy : drain_policy
end

type adapter = (module S)

let adapters : (string, adapter) Hashtbl.t = Hashtbl.create 8

let register (module A : S) =
  Hashtbl.replace adapters A.kind (module A : S)

let find kind : adapter option =
  try Some (Hashtbl.find adapters kind) with Not_found -> None

let list_kinds () =
  Hashtbl.fold (fun k _ acc -> k :: acc) adapters [] |> List.sort String.compare

(** Derive a kimi endpoint from a registration (no delivery_endpoint field yet). *)
let endpoint_of_kimi_reg ~broker_root (reg : C2c_mcp.registration) : endpoint option =
  let ct_ok =
    match reg.client_type with
    | Some ct -> String.lowercase_ascii (String.trim ct) = "kimi"
    | None ->
        (match reg.registered_by with
         | Some rb ->
             let rb = String.lowercase_ascii rb in
             rb = "kimi-hook" || rb = "kimi"
         | None -> false)
  in
  if not ct_ok then None
  else
    match reg.cwd with
    | Some w when String.trim w <> "" ->
        Some
          { kind = "kimi"
          ; broker_root
          ; session_id = reg.session_id
          ; alias = reg.alias
          ; workdir = Some (String.trim w)
          }
    | _ -> None

(* ─── Kimi adapter ────────────────────────────────────────────────────────── *)

module Kimi : S = struct
  let kind = "kimi"
  let drain_policy = After_push

  let probe (ep : endpoint) : probe_result =
    match C2c_kimi_deliver.server_base_url () with
    | None -> `Dead "no kimi server base url"
    | Some url ->
        if not (C2c_kimi_deliver.address_is_live url) then
          `Dead ("kimi server not live: " ^ url)
        else
          (match ep.workdir with
           | None -> `Unknown
           | Some wd ->
               (match C2c_kimi_notifier.resolve_kimi_session_id ~cwd:wd () with
                | Some _ -> `Live
                | None -> `Unknown))

  let deliver (ep : endpoint) (msg : C2c_mcp.message) : (unit, string) result =
    match ep.workdir with
    | None -> Error "kimi endpoint missing workdir"
    | Some wd ->
        (match C2c_kimi_notifier.resolve_kimi_session_id ~cwd:wd () with
         | None -> Error "cannot resolve kimi session id for workdir"
         | Some kid -> C2c_kimi_deliver.deliver_message ~session_id:kid ~msg)
end

let () = register (module Kimi)

let drain_policy_to_string = function
  | After_push -> "after_push"
  | Hooks_own_drain -> "hooks_own_drain"
  | Never -> "never"

let probe_to_string = function
  | `Live -> "live"
  | `Dead s -> "dead:" ^ s
  | `Unknown -> "unknown"
