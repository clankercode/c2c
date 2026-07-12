(* Alias blocklist applied to USER-SUPPLIED names only.
   Auto-generated names are client-prefixed (e.g. codex-ember-frost) and bypass
   this list via [Broker.register ~from_auto_gen:true]. *)

let banned_aliases =
  [ "gpt"
  ; "assistant"
  ; "claude"
  ; "codex"
  ; "opencode"
  ; "kimi"
  ; "crush"
  ]

let alias_casefold s = String.lowercase_ascii s

let first_segment s =
  match String.index_opt s '-' with
  | None -> s
  | Some i -> String.sub s 0 i

let is_banned_alias alias =
  let folded = alias_casefold alias in
  let first = alias_casefold (first_segment alias) in
  List.exists
    (fun banned ->
       let b = alias_casefold banned in
       b = folded || b = first)
    banned_aliases

let suggested_alias_for_blocked_alias alias =
  let valid_candidate s =
    s <> "" && C2c_name.is_valid s && not (is_banned_alias s)
  in
  let suffix_candidate =
    match String.index_opt alias '-' with
    | Some i when i + 1 < String.length alias ->
        Some (String.sub alias (i + 1) (String.length alias - i - 1))
    | _ -> None
  in
  match suffix_candidate with
  | Some suffix when valid_candidate suffix -> suffix
  | _ ->
      let prefixed = "agent-" ^ alias in
      if valid_candidate prefixed then prefixed else "agent-name"

let blocked_alias_error alias =
  Printf.sprintf
    "register rejected: '%s' is a blocked alias. Names equal to reserved \
     client/system aliases or starting with reserved client prefixes are \
     reserved for auto-generated client identities. Try '%s' or pick a name \
     not starting with a reserved client prefix (claude-, codex-, opencode-, \
     kimi-, crush-)."
    alias (suggested_alias_for_blocked_alias alias)
