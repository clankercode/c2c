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

let signature_invalid_hint = function
  | Explicit alias ->
      Printf.sprintf
        "hint: relay rejected the Ed25519 request signature for alias %S.\n\
        \  Common causes after rename/register:\n\
        \    1. Local identity differs from the key bound on the relay\n\
        \       (check: c2c relay identity show — then re-register)\n\
        \    2. Stale lease under the old alias (register the new alias)\n\
        \  Fix:  c2c relay register --alias %s\n\
        \  Then: c2c whoami --relay\n\
        \  If it still fails, the error detail names bound_pk / path / body_sha256.\n"
        alias alias
  | Anon_fallback ->
      "hint: relay rejected the Ed25519 request signature (signed as \"anon\").\n\
      \  Fix: pass --alias <your-alias> or set C2C_MCP_AUTO_REGISTER_ALIAS,\n\
      \  then: c2c relay register --alias <your-alias>\n"

(* [hint_for_response ~alias_source json] returns the hint to print on
   stderr when [json] is a missing-identity-binding auth error or a
   signature_invalid error (B184), or None for every other response
   (including success). Missing-binding takes precedence if both ever
   matched (they use different error_codes today). *)
let hint_for_response ~alias_source (json : Yojson.Safe.t) =
  if is_missing_identity_binding json then Some (missing_binding_hint alias_source)
  else if is_signature_invalid json then Some (signature_invalid_hint alias_source)
  else None
