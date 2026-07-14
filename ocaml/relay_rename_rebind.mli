(** B179: post-rename relay identity rebind.

    After a successful local [Broker.rename_alias], the new alias still needs
    an identity binding on any configured relay (same Ed25519 key as
    [c2c relay register --alias]). Without that rebind, [c2c monitor]
    relay peeks fail TERMINAL with
    [unauthorized: alias "<new>" has no identity binding].

    This module is the shared path for CLI [c2c rename] and the MCP [rename]
    tool. Failures never roll back a completed local rename; callers merge
    the structured result into rename output and print a copy-pasteable
    next step when rebind cannot complete. *)

(** [next_step_command ~new_alias] is the operator-facing fix command when
    automatic rebind cannot run or fails. *)
val next_step_command : new_alias:string -> string

(** Resolve the configured relay URL the same way as [c2c relay register]
    (flag not available here): [C2C_RELAY_URL], else [C2C_RELAY_CONFIG] /
    broker-root [relay.json] / [~/.config/c2c/relay.json] [url] field.
    Does NOT invent a default public URL — no config means skip rebind. *)
val resolve_relay_url : unit -> string option

(** Resolve optional bearer token: [C2C_RELAY_TOKEN], else config [token]. *)
val resolve_relay_token : unit -> string option

(** Best-effort signed register of [new_alias] on the configured relay
    using the local Ed25519 identity (same code path as
    [c2c relay register --alias]).

    Returns a JSON object always suitable for embedding under
    [relay_rebind] in rename results:

    - [status: "skipped"] — no relay URL configured (local-only rename).
    - [status: "ok"] — new alias bound; [old_alias_lease] describes the
      dual-bind window for the prior name (TTL expiry).
    - [status: "error"] — rebind failed; includes [error] and
      [next_step] (copy-pasteable [c2c relay register --alias=...]).

    Optional [~relay_url] / [~token] override env/config (tests).
    Short client timeout so a dead relay cannot hang rename. *)
val rebind_lwt :
  ?relay_url:string ->
  ?token:string ->
  old_alias:string ->
  new_alias:string ->
  unit ->
  Yojson.Safe.t Lwt.t

(** Blocking wrapper around [rebind_lwt] for CLI / sync callers.
    Must not be invoked from inside an existing [Lwt_main.run]. *)
val rebind_sync :
  ?relay_url:string ->
  ?token:string ->
  old_alias:string ->
  new_alias:string ->
  unit ->
  Yojson.Safe.t

(** Merge a rename-result JSON object with a [relay_rebind] field.
    Non-assoc rename results pass through unchanged. *)
val merge_into_rename_result :
  rename_json:Yojson.Safe.t -> rebind_json:Yojson.Safe.t -> Yojson.Safe.t
