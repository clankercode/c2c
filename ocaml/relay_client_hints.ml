(* Relay_client_hints — client-side actionable hints for relay error
   responses.

   The relay's signed peer routes reject a request whose claimed alias has no
   alias→identity binding registered server-side. The server has no dedicated
   error_code for this case — try_verify_ed25519_request (relay.ml) and the
   WS subscribe path (relay_ws_server.ml) both emit the generic code
   "unauthorized" with the message

     alias "<alias>" has no identity binding

   so the CLI keys off error_code first and then the stable message
   substring. If the relay ever grows a structured code for this case
   (e.g. "identity_binding_missing"), add it to
   [is_missing_identity_binding] and drop the substring match. *)

type alias_source =
  | Explicit of string
      (* The request was signed as an alias the caller supplied
         (--alias flag or C2C_MCP_AUTO_REGISTER_ALIAS). *)
  | Anon_fallback
      (* No alias could be resolved for this session; the request was signed
         with the "anon" placeholder alias (which no relay in practice has a
         binding for). *)

(* #81: what the CLIENT knows about a `contact_unauthorised` rejection.

   The relay cannot tell us which of the admission checks failed — G6
   (relay.ml handle_contact_deliver) makes every denial share one external
   shape on purpose, so the code cannot be used to enumerate which aliases
   exist. That privacy property is not negotiable, so the disambiguation has
   to happen client-side, from facts the client can check locally.

   [recipient_live_locally] is the one that resolves the reported confusion:
   a peer alive on a local broker needs no relay hop at all. The caller
   computes it (this module stays pure and hermetically testable); [None]
   means the caller did not look, not that the peer is absent. *)
type contact_context = {
  recipient : string;
  recipient_live_locally : bool option;
}

let contains_substring ~needle haystack =
  let nlen = String.length needle and hlen = String.length haystack in
  if nlen = 0 then true
  else begin
    let found = ref false in
    let i = ref 0 in
    while (not !found) && !i <= hlen - nlen do
      if String.sub haystack !i nlen = needle then found := true;
      incr i
    done;
    !found
  end

(* True when [json] is a relay error response caused by the claimed alias
   having no identity binding on the relay. *)
let is_missing_identity_binding (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let ok =
        match List.assoc_opt "ok" fields with
        | Some (`Bool b) -> b
        | _ -> false
      in
      let code_matches =
        match List.assoc_opt "error_code" fields with
        | Some (`String "unauthorized") -> true
        | _ -> false
      in
      let msg_matches =
        match List.assoc_opt "error" fields with
        | Some (`String msg) ->
            contains_substring ~needle:"has no identity binding" msg
        | _ -> false
      in
      (not ok) && code_matches && msg_matches
  | _ -> false

(* Actionable fix-it text for a missing identity binding, shaped by how the
   signing alias was chosen. `c2c relay register --alias <alias>` is the real
   command that establishes the alias→identity binding on the relay (see
   relay_register_cmd in ocaml/cli/c2c_relay_cmd.ml, POST /register with a
   signed Ed25519 proof). *)
let missing_binding_hint = function
  | Explicit alias ->
      Printf.sprintf
        "hint: the relay has no identity binding for alias %S.\n\
        \  Your local Ed25519 identity is not registered under that alias yet.\n\
        \  Fix:  c2c relay register --alias %s\n\
        \  Then retry. (Inspect the local identity with: c2c relay identity show)\n"
        alias alias
  | Anon_fallback ->
      "hint: no session alias was found, so the request was signed as \"anon\",\n\
      \  which the relay has no identity binding for.\n\
      \  Fix: pass --alias <your-alias> (or set C2C_MCP_AUTO_REGISTER_ALIAS,\n\
      \  or run `c2c init` to set up a session alias), and make sure that\n\
      \  alias is registered with the relay:\n\
      \    c2c relay register --alias <your-alias>\n"

(* True when [json] is a signature_invalid rejection of a signed peer
   request (try_verify_ed25519_request). Distinct from missing binding:
   the alias IS bound, but the proof does not verify against that key —
   typically wire-body vs sign-body mismatch (B184) or wrong identity
   after rename/register on another machine. *)
let is_signature_invalid (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let ok =
        match List.assoc_opt "ok" fields with
        | Some (`Bool b) -> b
        | _ -> false
      in
      let code_matches =
        match List.assoc_opt "error_code" fields with
        | Some (`String "signature_invalid") -> true
        | _ -> false
      in
      (not ok) && code_matches
  | _ -> false

(* B231: signature_invalid for a session-scoped route (poll/peek/heartbeat)
   when the verified alias is bound but does not own the body (node_id,
   session_id). Server format (relay.ml reject_session_mismatch):
     verified signer %S does not own session (%s, %s)
   Distinct from a bad Ed25519 proof — re-registering steals the lease from
   a live relay-connect and makes the two fight over the alias. *)
let is_session_ownership_failure (json : Yojson.Safe.t) =
  if not (is_signature_invalid json) then false
  else
    match json with
    | `Assoc fields ->
        (match List.assoc_opt "error" fields with
         | Some (`String msg) ->
             contains_substring ~needle:"does not own session" msg
         | _ -> false)
    | _ -> false

let session_ownership_hint = function
  | Explicit alias ->
      Printf.sprintf
        "hint: alias %S is bound, but this request targeted a session key it\n\
        \  does not currently own (often cli-%s while relay-connect holds the\n\
        \  live lease under the connector node/session).\n\
        \  Do NOT run `c2c relay register` — that steals the lease from the\n\
        \  connector; the two then fight and delivery wedges.\n\
        \  Fix:\n\
        \    - Keep `c2c start relay-connect` (or `c2c relay connect`) running;\n\
        \      inbound DMs land in the local broker inbox.\n\
        \    - For relay inspection: `c2c relay dm peek --alias %s` (uses the\n\
        \      connector lease when connector-state.json is present).\n\
        \    - Check: c2c whoami --relay  /  c2c status --relay\n"
        alias alias alias
  | Anon_fallback ->
      "hint: signed as \"anon\" and the session key is not owned by that alias.\n\
      \  Fix: pass --alias <your-alias> (or set C2C_MCP_AUTO_REGISTER_ALIAS).\n\
      \  Do NOT re-register just to force a cli-<alias> lease if relay-connect\n\
      \  is already managing the alias — keep the connector and use local inbox.\n"

let signature_invalid_hint = function
  | Explicit alias ->
      Printf.sprintf
        "hint: relay rejected the Ed25519 request signature for alias %S.\n\
        \  Common causes after rename/register:\n\
        \    1. Local identity differs from the key bound on the relay\n\
        \       (check: c2c relay identity show — then re-register)\n\
        \    2. Stale lease under the old alias (register the new alias)\n\
        \  If the error says \"does not own session\", a live connector already\n\
        \  holds the lease — do NOT re-register (see session-ownership hint).\n\
        \  Fix (true signature mismatch only):  c2c relay register --alias %s\n\
        \  Then: c2c whoami --relay\n\
        \  If it still fails, the error detail names bound_pk / path / body_sha256.\n"
        alias alias
  | Anon_fallback ->
      "hint: relay rejected the Ed25519 request signature (signed as \"anon\").\n\
      \  Fix: pass --alias <your-alias> or set C2C_MCP_AUTO_REGISTER_ALIAS,\n\
      \  then: c2c relay register --alias <your-alias>\n"

(* #81: True when [json] is the relay's uniform admission denial. On /send
   this is emitted when the RECIPIENT alias has no live registration on the
   relay (handle_send maps relay_err_unknown_alias to it); on
   /contact/v1/deliver it also covers unknown/malformed/expired/revoked
   grants, dev-mode relays and non-confidential transport. The client cannot
   tell those apart from the response, by design (G6). *)
let is_contact_unauthorised (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      let ok =
        match List.assoc_opt "ok" fields with
        | Some (`Bool b) -> b
        | _ -> false
      in
      let code_matches =
        match List.assoc_opt "error_code" fields with
        | Some (`String "contact_unauthorised") -> true
        | _ -> false
      in
      (not ok) && code_matches
  | _ -> false

(* The single most useful thing to say about a contact_unauthorised: if the
   peer is alive on a broker on THIS machine, the relay hop was never needed.
   That is #81's whole reported symptom — "recipient is healthy locally but
   the relay says unauthorised" reads as an ACL rejection when it is really a
   routing mistake. Rendered only when the caller actually resolved the
   recipient's local liveness. *)
let contact_local_reachability_note = function
  | None -> ""
  | Some { recipient; recipient_live_locally = Some true } ->
      Printf.sprintf
        "\n\
        \  BUT: that peer is alive on a broker on THIS machine, so none of\n\
        \  the above needs fixing — the relay hop was not required at all.\n\
        \  Send locally instead:\n\
        \    c2c send %s \"...\"\n\
        \  The relay carries CROSS-MACHINE mail only (<alias>@<host_id>).\n"
        recipient
  | Some { recipient_live_locally = Some false; _ } ->
      "\n\
      \  (That peer is not alive on any broker on this machine, so the relay\n\
      \  is the right transport here — one of (1)-(3) applies.)\n"
  | Some { recipient_live_locally = None; _ } -> ""

let contact_unauthorised_hint ~alias_source ~contact =
  let signer =
    match alias_source with
    | Explicit a -> a
    | Anon_fallback -> "anon"
  in
  let recipient =
    match contact with Some { recipient; _ } -> recipient | None -> "<recipient>"
  in
  Printf.sprintf
    "hint: the relay answered \"contact unauthorised\". That is its UNIFORM\n\
    \  admission-denial code: every rejected delivery gets the identical\n\
    \  response on purpose, so that nobody can use it to discover which\n\
    \  aliases exist on the relay. It therefore does NOT mean the peer\n\
    \  blocked you, and it cannot tell you which of these applies. Check\n\
    \  them locally, most likely first:\n\
    \    1. The recipient has no live registration on the relay. Only\n\
    \       they can fix that, from their own machine:\n\
    \         c2c relay register --alias %s\n\
    \       See who is currently reachable:\n\
    \         c2c relay list\n\
    \    2. Their reachability is private and you hold no contact grant.\n\
    \       Grants are recipient-issued:\n\
    \         c2c relay contact\n\
    \    3. Your own side cannot send as %S: no identity binding, no\n\
    \       connector, or an expired lease.\n\
    \         c2c whoami --relay     (your alias to identity binding)\n\
    \         c2c status --relay     (connector and lease state)\n\
     %s"
    recipient signer
    (contact_local_reachability_note contact)

(* [hint_for_response ?contact ~alias_source json] returns the hint to print
   on stderr when [json] is a missing-identity-binding auth error, a
   session-ownership signature_invalid (B231), a generic signature_invalid
   error (B184), or a contact_unauthorised admission denial (#81) — and None
   for every other response (including success). Precedence: missing-binding
   > session-ownership > generic signature_invalid > contact_unauthorised.
   The codes are disjoint, so the order is documentation rather than a
   tie-break. [?contact] sharpens the contact_unauthorised text and is
   ignored for the others. *)
let hint_for_response ?contact ~alias_source (json : Yojson.Safe.t) =
  if is_missing_identity_binding json then Some (missing_binding_hint alias_source)
  else if is_session_ownership_failure json then
    Some (session_ownership_hint alias_source)
  else if is_signature_invalid json then Some (signature_invalid_hint alias_source)
  else if is_contact_unauthorised json then
    Some (contact_unauthorised_hint ~alias_source ~contact)
  else None
