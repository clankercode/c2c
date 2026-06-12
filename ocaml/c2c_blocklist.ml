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
  ; "gemini"
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
