(* Hoisted from c2c_mcp.ml as part of #450 Slice 0 — substrate for
   handler-cluster extraction (S1-S7). Pure mechanical move; no behavior
   change. Types and pre-Broker helpers live in [C2c_mcp_helpers]. *)

open C2c_mcp_helpers

  type t = {
    root : string;
    deprecate_canonical_alias : bool;
  }

  (* Hardening B: prior-mismatch state — tracks which aliases were last
     observed in mismatch state. Used to suppress WORKTREE_MATCH log spam:
     only log when transitioning mismatch→match, not on every send.
     Keys are casefolded aliases; values are bool (true=mismatch, false=match). *)
  let prior_mismatch_state : (string, bool) Hashtbl.t = Hashtbl.create 64

  (* Process-scan hooks for the pid self-heal path. Default to real
     /proc; tests can swap in mocks via [set_proc_hooks_for_test]. The
     hooks are module-globals (a single test running at a time is the
     norm in this suite). Set back to None to clear. *)
  let proc_scan_pids_override : (unit -> (unit -> int list)) option ref = ref None
  let proc_read_environ_override : (unit -> (int -> (string * string) list option)) option ref = ref None

  let set_proc_hooks_for_test ?scan_pids ?read_environ () =
    proc_scan_pids_override :=
      (match scan_pids with None -> None | Some f -> Some (fun () -> f));
    proc_read_environ_override :=
      (match read_environ with None -> None | Some f -> Some (fun () -> f))

  let clear_proc_hooks_for_test () =
    proc_scan_pids_override := None;
    proc_read_environ_override := None

  let registry_path t = Filename.concat t.root "registry.json"
  let inbox_path t ~session_id = Filename.concat t.root (session_id ^ ".inbox.json")

  let ensure_root t = mkdir_p t.root

  (** [log_json_cap_exceeded ~broker_root ~path ~max_bytes] emits a
      best-effort broker.log audit line when a JSON file is rejected
      because it exceeds [max_bytes]. Silently ignores all errors so
      logging never blocks the read path. Follow-up to Slice F
      (fern non-blocking note: operators need observability when the
      cap triggers). *)
  let log_json_cap_exceeded ~broker_root ~path ~max_bytes =
    (try
       let log_path = Filename.concat broker_root "broker.log" in
       let line =
         `Assoc
           [ ("ts", `Float (Unix.gettimeofday ()))
           ; ("event", `String "json_cap_exceeded")
           ; ("file", `String path)
           ; ("max_bytes", `Int max_bytes)
           ]
         |> Yojson.Safe.to_string
       in
        let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 log_path in
        (try output_string oc (line ^ "\n"); close_out oc
         with _ -> close_out_noerr oc)
     with _ -> ())

  let read_json_file ?broker_root path ~default =
    if Sys.file_exists path then
      (* 64 KiB cap: registration blobs, relay state, and config files
         are operator-controlled but may be attacker-adjacent (e.g. a
         compromised peer writing an oversized blob to the shared relay
         directory). A parse-cap of 64 KiB is ample for any legitimate
         broker artifact and prevents unbounded memory allocation from
         maliciously large files. Slice F. *)
      let content = C2c_io.read_file_opt path in
      let size = String.length content in
      if size > 64 * 1024 then begin
        (match broker_root with
         | Some root ->
           log_json_cap_exceeded ~broker_root:root ~path ~max_bytes:(64 * 1024)
         | None -> ());
        default
      end else
        (try Yojson.Safe.from_string content with _ -> default)
    else default

  let write_json_file path json =
    (* Atomic write via temp+rename+fsync. A truncate-in-place writer that
       gets SIGKILLed (OOM, parent process exit, kill -9) between
       truncate and full write leaves a partial JSON file that the
       next reader will fail to parse. Writing to a per-pid sidecar
       and then Unix.rename'ing into place gives readers an
       all-or-nothing view: they always see either the old content
       or the new content, never partial. The rename is atomic on
       POSIX as long as src and dst are on the same filesystem,
       which they are by construction (sidecar lives next to the
       target). The 0o600 mode policy is preserved on the temp file,
       which becomes the destination inode after rename.
       #54: fsync before rename ensures the temp file's data is flushed
       to disk before the atomic-replace rename commits it, so readers
       always see either old or new content, never partial. *)
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    (* Not append_jsonl: atomic-replace write-to-tmp + fsync + rename. *)
    let oc =
      open_out_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_text ]
        0o600 tmp
    in
    let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
    (try
       Fun.protect
         ~finally:(fun () -> try close_out oc with _ -> ())
         (fun () ->
            Yojson.Safe.to_channel oc json;
            flush oc;
            (* #54: fsync before rename ensures the temp file's data is flushed
               to disk before the atomic-replace rename commits it, so readers
               always see either old or new content, never partial.
               Best-effort — EINVAL on unusual filesystems is silently ignored. *)
            (try Unix.fsync (Unix.descr_of_out_channel oc) with Unix.Unix_error _ -> ()))
     with e ->
       cleanup_tmp ();
       raise e);
    try Unix.rename tmp path
    with e ->
      cleanup_tmp ();
      raise e

  let registration_to_json { session_id; alias; pid; pid_start_time; registered_at; canonical_alias; dnd; dnd_since; dnd_until; client_type; plugin_version; confirmed_at; enc_pubkey; ed25519_pubkey; pubkey_signed_at; pubkey_sig; compacting; last_activity_ts; role; compaction_count; automated_delivery; tmux_location; herdr_pane; herdr_socket; cwd; metadata_opt_out; registered_by; opaque_host_id = _ } =
    let base =
      [ ("session_id", `String session_id); ("alias", `String alias) ]
    in
    let with_pid =
      match pid with
      | Some n -> base @ [ ("pid", `Int n) ]
      | None -> base
    in
    let with_pst =
      match pid_start_time with
      | Some n -> with_pid @ [ ("pid_start_time", `Int n) ]
      | None -> with_pid
    in
    let with_ra =
      match registered_at with
      | Some ts -> with_pst @ [ ("registered_at", `Float ts) ]
      | None -> with_pst
    in
    let with_ca =
      match canonical_alias with
      | Some ca -> with_ra @ [ ("canonical_alias", `String ca) ]
      | None -> with_ra
    in
    (* Only persist DND when enabled — keeps registry compact for normal case. *)
    let with_dnd =
      if dnd then with_ca @ [ ("dnd", `Bool true) ]
      else with_ca
    in
    let with_dnd_since =
      match dnd_since with
      | Some ts when dnd -> with_dnd @ [ ("dnd_since", `Float ts) ]
      | _ -> with_dnd
    in
    let with_dnd_until =
      match dnd_until with
      | Some ts when dnd -> with_dnd_since @ [ ("dnd_until", `Float ts) ]
      | _ -> with_dnd_since
    in
    let with_client_type =
      match client_type with
      | Some ct -> with_dnd_until @ [ ("client_type", `String ct) ]
      | None -> with_dnd_until
    in
    let with_plugin_version =
      match plugin_version with
      | Some pv -> with_client_type @ [ ("plugin_version", `String pv) ]
      | None -> with_client_type
    in
    let with_confirmed =
      match confirmed_at with
      | Some ts -> with_plugin_version @ [ ("confirmed_at", `Float ts) ]
      | None -> with_plugin_version
    in
    let with_enc_pubkey =
      match enc_pubkey with
      | Some pk -> with_confirmed @ [ ("enc_pubkey", `String pk) ]
      | None -> with_confirmed
    in
    let with_ed25519_pubkey =
      match ed25519_pubkey with
      | Some pk -> with_enc_pubkey @ [ ("ed25519_pubkey", `String pk) ]
      | None -> with_enc_pubkey
    in
    let with_pubkey_signed_at =
      match pubkey_signed_at with
      | Some ts -> with_ed25519_pubkey @ [ ("pubkey_signed_at", `Float ts) ]
      | None -> with_ed25519_pubkey
    in
    let with_pubkey_sig =
      match pubkey_sig with
      | Some s -> with_pubkey_signed_at @ [ ("pubkey_sig", `String s) ]
      | None -> with_pubkey_signed_at
    in
    let fields =
      match compacting with
      | Some c ->
          let reason_json = match c.reason with Some r -> `String r | None -> `Null in
          with_pubkey_sig @ [ ("compacting", `Assoc [ ("started_at", `Float c.started_at); ("reason", reason_json) ]) ]
      | None -> with_pubkey_sig
    in
    let with_last_activity_ts =
      match last_activity_ts with
      | Some ts -> fields @ [ ("last_activity_ts", `Float ts) ]
      | None -> fields
    in
    let with_role =
      match role with
      | Some r -> with_last_activity_ts @ [ ("role", `String r) ]
      | None -> with_last_activity_ts
    in
    let with_compaction_count =
      if compaction_count > 0 then with_role @ [ ("compaction_count", `Int compaction_count) ]
      else with_role
    in
    let with_automated_delivery =
      match automated_delivery with
      | Some b -> with_compaction_count @ [ ("automated_delivery", `Bool b) ]
      | None -> with_compaction_count
    in
    (* Wake-target metadata (codex-wake-inject slice). tmux_location was
       declared persisted by #517 but the destructure silently dropped it
       (warning-9 masked) — fixed here so `c2c list` and the wake injector
       can read targets back from the registry across processes. *)
    let with_tmux_location =
      match tmux_location with
      | Some loc -> with_automated_delivery @ [ ("tmux_location", `String loc) ]
      | None -> with_automated_delivery
    in
    let with_herdr_pane =
      match herdr_pane with
      | Some p -> with_tmux_location @ [ ("herdr_pane", `String p) ]
      | None -> with_tmux_location
    in
    let with_herdr_socket =
      match herdr_socket with
      | Some s -> with_herdr_pane @ [ ("herdr_socket", `String s) ]
      | None -> with_herdr_pane
    in
    let with_cwd =
      match cwd with
      | Some c -> with_herdr_socket @ [ ("cwd", `String c) ]
      | None -> with_herdr_socket
    in
    (* Only persist metadata_opt_out when true — keeps registry compact for normal case. *)
    let with_metadata_opt_out =
      if metadata_opt_out then with_cwd @ [ ("metadata_opt_out", `Bool true) ]
      else with_cwd
    in
    let with_registered_by =
      match registered_by with
      | Some rb -> with_metadata_opt_out @ [ ("registered_by", `String rb) ]
      | None -> with_metadata_opt_out
    in
    `Assoc with_registered_by

  let int_opt_member name json =
    let open Yojson.Safe.Util in
    try
      match json |> member name with
      | `Null -> None
      | `Int n -> Some n
      | _ -> None
    with _ -> None

  let float_opt_member name json =
    let open Yojson.Safe.Util in
    try
      match json |> member name with
      | `Null -> None
      | `Float f -> Some f
      | `Int n -> Some (float_of_int n)
      | _ -> None
    with _ -> None

  let registration_of_json json =
    let open Yojson.Safe.Util in
    let str_opt name j =
      try match j |> member name with `String s -> Some s | _ -> None
      with _ -> None
    in
    let bool_member_default name j default =
      try match j |> member name with `Bool b -> b | _ -> default
      with _ -> default
    in
    let compacting_of_json j =
      match j |> member "compacting" with
      | `Null -> None
      | `Assoc _ ->
          Some { started_at = j |> member "compacting" |> member "started_at" |> to_float;
                 reason = str_opt "reason" (j |> member "compacting") }
      | _ -> None
    in
    { session_id = json |> member "session_id" |> to_string
    ; alias = json |> member "alias" |> to_string
    ; pid = int_opt_member "pid" json
    ; pid_start_time = int_opt_member "pid_start_time" json
    ; registered_at = float_opt_member "registered_at" json
    ; canonical_alias = str_opt "canonical_alias" json
    ; dnd = bool_member_default "dnd" json false
    ; dnd_since = float_opt_member "dnd_since" json
    ; dnd_until = float_opt_member "dnd_until" json
    ; client_type = str_opt "client_type" json
    ; plugin_version = str_opt "plugin_version" json
    ; confirmed_at = float_opt_member "confirmed_at" json
    ; enc_pubkey = str_opt "enc_pubkey" json
    ; ed25519_pubkey = str_opt "ed25519_pubkey" json
    ; pubkey_signed_at = float_opt_member "pubkey_signed_at" json
    ; pubkey_sig = str_opt "pubkey_sig" json
    ; compacting = compacting_of_json json
    ; last_activity_ts = float_opt_member "last_activity_ts" json
    ; role = str_opt "role" json
    ; compaction_count = (match json |> member "compaction_count" with `Int n -> n | _ -> 0)
    ; automated_delivery =
        (try match json |> member "automated_delivery" with
             | `Bool b -> Some b
             | _ -> None
         with _ -> None)
    ; tmux_location = str_opt "tmux_location" json
    ; herdr_pane = str_opt "herdr_pane" json
    ; herdr_socket = str_opt "herdr_socket" json
    ; cwd = str_opt "cwd" json
    ; metadata_opt_out = bool_member_default "metadata_opt_out" json false
    ; registered_by = str_opt "registered_by" json
    ; opaque_host_id = str_opt "opaque_host_id" json
    }

  let message_to_json { from_alias; to_alias; content; deferrable; reply_via; enc_status; ts; ephemeral; message_id; pow_difficulty } =
    let base =
      [ ("from_alias", `String from_alias)
      ; ("to_alias", `String to_alias)
      ; ("content", `String content)
      ; ("ts", `Float ts)
      ]
    in
    let with_deferrable = if deferrable then base @ [("deferrable", `Bool true)] else base in
    let with_ephemeral = if ephemeral then with_deferrable @ [("ephemeral", `Bool true)] else with_deferrable in
    let with_reply_via = match reply_via with None -> with_ephemeral | Some rv -> with_ephemeral @ [("reply_via", `String rv)] in
    let with_msg_id = match message_id with None -> with_reply_via | Some mid -> with_reply_via @ [("message_id", `String mid)] in
    (* B014: preserve the sender's PoW difficulty across the inbox-file
       round-trip as the self-describing [pow] object. *)
    let with_pow = match pow_difficulty with
      | Some d when d >= 0 -> Relay_pow_challenge.with_pow_meta ~difficulty:d with_msg_id
      | _ -> with_msg_id
    in
    match enc_status with
    | None -> `Assoc with_pow
    | Some es -> `Assoc (with_pow @ [("enc_status", `String es)])

  (* B014: parse the sender's PoW difficulty. Canonical wire form is the [pow]
     object ([pow.difficulty_bits]); a bare int [pow_difficulty] is also accepted
     for robustness. Negative/absent → [None]. *)
  let pow_difficulty_of_json json =
    let open Yojson.Safe.Util in
    let bits =
      match json |> member "pow" with
      | `Assoc _ as pow ->
        (match pow |> member "difficulty_bits" with
         | `Int i -> Some i
         | _ -> None)
      | _ ->
        (match json |> member "pow_difficulty" with
         | `Int i -> Some i
         | _ -> None)
    in
    match bits with Some i when i >= 0 -> Some i | _ -> None

  let message_of_json json =
    let open Yojson.Safe.Util in
    { from_alias = json |> member "from_alias" |> to_string
    ; to_alias = json |> member "to_alias" |> to_string
    ; content = json |> member "content" |> to_string
    ; deferrable =
        (match json |> member "deferrable" with
         | `Bool b -> b
         | _ -> false)
    ; reply_via =
        (match json |> member "reply_via" with
         | `String s -> Some s
         | _ -> None)
    ; enc_status =
        (match json |> member "enc_status" with
         | `String s -> Some s
         | _ -> None)
    ; ts =
        (match json |> member "ts" with
         | `Float f -> f
         | `Int i -> float_of_int i
         | _ -> 0.0)
    ; ephemeral =
        (match json |> member "ephemeral" with
         | `Bool b -> b
         | _ -> false)
    ; message_id =
        (match json |> member "message_id" with
         | `String s when s <> "" -> Some s
         | _ -> None)
    ; pow_difficulty = pow_difficulty_of_json json
    }

  (* Lowercase comparison helper: aliases are case-insensitive for collision
     detection (lyra-quill and Lyra-Quill are the same identity). The stored
     alias preserves original case; this only affects lookups.
     Hoisted above [load_registrations] so the case-fold invariant check
     in [save_registrations] can reach it. Also reachable from earlier
     callers (e.g. [pending_permission_exists_for_alias]) so every
     alias-comparison site in this module routes through this helper:
     the symmetric eviction predicate at L1898, the M4 alias-reuse guard
     at L848, the hijack guards at L4704+5074, and the pending-perm guard. *)
  let alias_casefold s = String.lowercase_ascii s

  let codex_hook_registered_by = "codex-hook"
  let claude_hook_registered_by = "claude-hook"
  let codex_hook_auto_registration_ttl_s = 24.0 *. 60.0 *. 60.0

  let is_codex_hook_auto_registration reg =
    reg.registered_by = Some codex_hook_registered_by

  (* B119: hook auto-registrations (SessionStart hooks of any client) are the
     identity authority for their session_id — the MCP server adopts them. *)
  let is_hook_auto_registration reg =
    reg.registered_by = Some codex_hook_registered_by
    || reg.registered_by = Some claude_hook_registered_by

  let codex_hook_activity_anchor reg =
    match reg.last_activity_ts with
    | Some ts -> Some ts
    | None -> reg.registered_at

  let is_expired_codex_hook_auto_registration reg =
    is_codex_hook_auto_registration reg
    && reg.pid = None
    &&
    match codex_hook_activity_anchor reg with
    | Some ts -> Unix.gettimeofday () -. ts > codex_hook_auto_registration_ttl_s
    | None -> false

  let load_registrations t =
    ensure_root t;
    match read_json_file ~broker_root:t.root (registry_path t) ~default:(`List []) with
    | `List items ->
        let regs = List.map registration_of_json items in
        if debug_enabled then Printf.eprintf "[DEBUG load_registrations] root=%s count=%d\n%!" t.root (List.length regs);
        regs
    | _ -> []

  (* #432: invariant — among ALIVE registrations, no two rows may share
     a case-folded alias. We only WARN (broker.log + stderr) — not
     reject — so partial-upgrade scenarios where the registry has
     pre-existing duplicates can heal themselves rather than wedge.
     Surfacing the duplicate is enough to point the next investigator
     at the resurrection bug class (galaxy-coder DM-misdelivery shape).
     Note: [registration_is_alive] depends on /proc + the lease table,
     so this check fires lazily — a stale row that the OS will GC will
     also stop tripping the invariant. *)
  let check_alias_casefold_invariant t regs =
    (* Inline liveness predicate — [registration_is_alive] is defined
       further down the module and depends on /proc/lease lookups; we
       only need a cheap "this row's pid still exists" check here. We
       intentionally exclude pid=None rows (legacy pidless / human
       sessions) from the duplicate-check: they cannot meaningfully
       compete for an alias with a real pidful registration. *)
    let alive_for_invariant reg =
      match reg.pid with
      | None -> false
      | Some pid -> Sys.file_exists ("/proc/" ^ string_of_int pid)
    in
    let alive = List.filter alive_for_invariant regs in
    let tbl = Hashtbl.create 16 in
    let dups = ref [] in
    List.iter
      (fun r ->
        let key = String.lowercase_ascii r.alias in
        match Hashtbl.find_opt tbl key with
        | None -> Hashtbl.add tbl key r
        | Some prior -> dups := (key, prior, r) :: !dups)
      alive;
    if !dups <> [] then begin
      try
        let path = Filename.concat t.root "broker.log" in
        let ts = Unix.gettimeofday () in
        List.iter
          (fun (key, prior, r) ->
            let line =
              `Assoc
                [ ("ts", `Float ts)
                ; ("event", `String "alias_casefold_invariant_violated")
                ; ("alias_casefold", `String key)
                ; ("alias_a", `String prior.alias)
                ; ("session_id_a", `String prior.session_id)
                ; ("alias_b", `String r.alias)
                ; ("session_id_b", `String r.session_id)
                ]
              |> Yojson.Safe.to_string
            in
            C2c_io.append_jsonl path line;
            Printf.eprintf
              "[Broker.save_registrations] WARN: case-fold alias collision among alive rows: \
               alias_casefold=%S (alias_a=%S session_a=%S, alias_b=%S session_b=%S)\n%!"
              key prior.alias prior.session_id r.alias r.session_id)
          !dups
      with _ -> ()
    end

  let save_registrations t regs =
    ensure_root t;
    check_alias_casefold_invariant t regs;
    write_json_file (registry_path t) (`List (List.map registration_to_json regs))

  let pending_permissions_path t = Filename.concat t.root "pending_permissions.json"

  let pending_permissions_lock_path t =
    Filename.concat t.root "pending_permissions.json.lock"

  (** [#432] Cross-process lock guarding pending_permissions.json. Separate
      from [registry.json.lock] so callers holding the registry lock (e.g.
      the M4 alias-reuse guard called from inside [Broker.register]) can
      acquire this without nested-lock release semantics. POSIX advisory
      locks (Unix.lockf F_LOCK / F_ULOCK on a fresh fd per call) — same
      mechanism as [with_registry_lock]. *)
  let with_pending_lock t f =
    ensure_root t;
    let fd =
      Unix.openfile (pending_permissions_lock_path t)
        [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  (* Primitives below — load/save/get_active. NOT individually locked.
     The four public API entry points (open/find/remove/exists_for_alias)
     wrap their bodies in [with_pending_lock]. *)
  let load_pending_permissions t =
    ensure_root t;
    match read_json_file ~broker_root:t.root (pending_permissions_path t) ~default:(`List []) with
    | `List items -> List.map pending_permission_of_json items
    | _ -> []

  let save_pending_permissions t entries =
    ensure_root t;
    write_json_file (pending_permissions_path t)
      (`List (List.map pending_permission_to_json entries))

  (** Remove expired entries on every access (lazy eviction). Callers get a
      clean list. Primitive — assumes caller holds [with_pending_lock] if
      atomicity matters (the four public API functions below all wrap). *)
  let get_active_pending_permissions t =
    let now = Unix.gettimeofday () in
    List.filter (fun p -> p.expires_at > now) (load_pending_permissions t)

  (** [#432 Slice C] Capacity bounds for the pending-permissions store.
      Per-alias and global caps prevent flooded JSON growth (which would
      degrade every register-time M4 guard scan) and bound a single
      bad/compromised caller's footprint. Numbers anchored on TTL=600s
      and ~1-2 in-flight per legitimate caller in a swarm of ~10-15
      live agents. *)
  let pending_per_alias_cap = 16
  let pending_global_cap = 1024

  exception Pending_capacity_exceeded of [`Per_alias of string | `Global]

  (** Persist a new pending permission entry. Cross-process safe via
      [with_pending_lock] (#432 Slice A). Raises
      [Pending_capacity_exceeded] when [pending_per_alias_cap] /
      [pending_global_cap] would be exceeded by the new entry (#432
      Slice C). *)
  let open_pending_permission t p =
    with_pending_lock t (fun () ->
      let entries = get_active_pending_permissions t in
      let global_count = List.length entries in
      if global_count >= pending_global_cap then
        raise (Pending_capacity_exceeded `Global);
      let per_alias_count =
        List.length
          (List.filter (fun e -> e.requester_alias = p.requester_alias)
             entries)
      in
      if per_alias_count >= pending_per_alias_cap then
        raise (Pending_capacity_exceeded (`Per_alias p.requester_alias));
      save_pending_permissions t (p :: entries))

  (** Find a pending permission by perm_id. Returns None if not found or
      expired. Cross-process safe via [with_pending_lock] (#432). *)
  let find_pending_permission t perm_id =
    with_pending_lock t (fun () ->
      let now = Unix.gettimeofday () in
      List.find_opt (fun p -> p.perm_id = perm_id && p.expires_at > now)
        (load_pending_permissions t))

  (** Remove a pending permission by perm_id. No-op if not found.
      Cross-process safe via [with_pending_lock] (#432). *)
  let remove_pending_permission t perm_id =
    with_pending_lock t (fun () ->
      let entries = List.filter (fun p -> p.perm_id <> perm_id)
        (get_active_pending_permissions t) in
      save_pending_permissions t entries)

  (** Check if any active pending permission exists for a given alias.
      Used by M4 alias-reuse guard. Cross-process safe via
      [with_pending_lock] (#432).

      [#432 follow-up (stanza-coder 2026-04-29)]: case-fold the alias
      comparison to match the symmetry restored across alias-eviction
      surfaces (Broker.register eviction at L1898; alias_hijack_conflict
      at L5074; alias_occupied_guard at L4704). A raw [=] here would
      have allowed a case-variant attempt to bypass the M4 alias-reuse
      block — composable with the now-closed hijack-then-evict path
      via slate's [e3c6aba0]. Closes the symmetry sweep. *)
  let pending_permission_exists_for_alias_unlocked t alias =
    let target = alias_casefold alias in
    List.exists
      (fun p -> alias_casefold p.requester_alias = target)
      (get_active_pending_permissions t)

  let pending_permission_exists_for_alias t alias =
    with_pending_lock t (fun () ->
      pending_permission_exists_for_alias_unlocked t alias)

  (* slice/coord-backup-fallthrough: stamp resolved_at on the entry whose
     perm_id matches. Returns true on first transition None→Some, false
     on no-op (already resolved or perm_id not found). Cross-process
     atomic via with_pending_lock. *)
  let mark_pending_resolved t ~perm_id ~ts ?(verdict:[ `Approve | `Deny] option=None) () =
    with_pending_lock t (fun () ->
      let entries = load_pending_permissions t in
      let changed = ref false in
      let updated =
        List.map
          (fun (p : pending_permission) ->
            if p.perm_id = perm_id && p.resolved_at = None then begin
              changed := true;
              { p with resolved_at = Some ts; verdict }
            end else p)
          entries
      in
      if !changed then save_pending_permissions t updated;
      !changed)

  (* slice/coord-backup-fallthrough: stamp [fallthrough_fired_at] at
     [tier_index]. Grows the list with [None] padding so index N is
     always addressable. Returns true on first transition for that
     index, false if already stamped (idempotent under double-tick).
     Cross-process atomic via with_pending_lock. *)
  let mark_pending_fallthrough_fired t ~perm_id ~tier_index ~ts =
    with_pending_lock t (fun () ->
      let entries = load_pending_permissions t in
      let changed = ref false in
      let pad_to n xs =
        let rec aux i acc =
          if i >= n then List.rev acc
          else
            let v = try List.nth xs i with _ -> None in
            aux (i + 1) (v :: acc)
        in
        aux 0 []
      in
      let stamp_at xs idx =
        List.mapi (fun i v -> if i = idx then Some ts else v) xs
      in
      let updated =
        List.map
          (fun (p : pending_permission) ->
            if p.perm_id <> perm_id then p
            else
              let len = max (List.length p.fallthrough_fired_at)
                           (tier_index + 1) in
              let padded = pad_to len p.fallthrough_fired_at in
              let already =
                try List.nth padded tier_index <> None with _ -> false
              in
              if already then p
              else begin
                changed := true;
                { p with fallthrough_fired_at = stamp_at padded tier_index }
              end)
          entries
      in
      if !changed then save_pending_permissions t updated;
      !changed)

  (** Parse a pending-verdict pattern from a message body.
      Pattern: [[c2c:pending-verdict:<perm_id>:<approve|deny>]]
      Returns [Some (perm_id, verdict)] on the first match, [None] otherwise.
      Empty perm_id or unknown verdict → [None]. *)
  let parse_pending_verdict content : (string * [ `Approve | `Deny]) option =
    let prefix = "[c2c:pending-verdict:" in
    let prefix_len = String.length prefix in
    match String.index_opt content '[' with
    | None -> None
    | Some _ ->
      (* Scan for the prefix substring anywhere in content *)
      let content_len = String.length content in
      let rec scan i =
        if i + prefix_len > content_len then None
        else if String.sub content i prefix_len = prefix then
          (* Found prefix at position i; find the closing ']' *)
          (match String.index_from_opt content (i + prefix_len) ']' with
           | None -> None
           | Some close_pos ->
             let inner = String.sub content (i + prefix_len)
                           (close_pos - i - prefix_len) in
             (* inner should be "perm_id:verdict" *)
             (match String.index_opt inner ':' with
              | None -> None
              | Some colon ->
                let perm_id = String.sub inner 0 colon in
                let verdict_str = String.sub inner (colon + 1)
                                    (String.length inner - colon - 1) in
                if perm_id = "" then None
                else match verdict_str with
                  | "approve" -> Some (perm_id, `Approve)
                  | "deny" -> Some (perm_id, `Deny)
                  | _ -> None))
        else scan (i + 1)
      in
      scan 0

  (* [#432 Slice E] In-memory relay-e2e TOFU pins were process-local —
     every broker restart silently downgraded x25519/ed25519
     first-seen-wins to "first-seen-this-process". Persisted to disk at
     <broker_root>/relay_pins.json, single file with two keyed
     sub-objects {"x25519": {alias: pk_b64}, "ed25519": {alias: pk_b64}}.
     Atomic write via [write_json_file] (tmp+rename); cross-process
     serialization via flock on [relay_pins.json.lock] (separate from
     registry / pending-permissions locks). The Hashtbls become a
     write-through cache: every public API call loads from disk under
     the lock and saves on mutation, so concurrent broker processes
     observe each other's pins. *)
  let relay_pins_root : string option ref = ref None

  let relay_pins_path () =
    match !relay_pins_root with
    | Some r -> Filename.concat r "relay_pins.json"
    | None -> failwith "relay_pins: broker root not set (call Broker.create first)"

  let relay_pins_lock_path () =
    match !relay_pins_root with
    | Some r -> Filename.concat r "relay_pins.json.lock"
    | None -> failwith "relay_pins: broker root not set (call Broker.create first)"

  (** [#432 Slice E] Cross-process flock guarding relay_pins.json. Separate
      from [registry.json.lock] and [pending_permissions.json.lock] so
      pin operations don't deadlock against registry/pending paths. POSIX
      advisory lock (Unix.lockf F_LOCK / F_ULOCK) on a fresh fd per call. *)
  let with_relay_pins_lock f =
    let r =
      match !relay_pins_root with
      | Some r -> r
      | None -> failwith "relay_pins: broker root not set"
    in
    mkdir_p r;
    let fd =
      Unix.openfile (relay_pins_lock_path ())
        [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let known_keys_ed25519 : (string, string) Hashtbl.t = Hashtbl.create 64
  let known_keys_x25519 : (string, string) Hashtbl.t = Hashtbl.create 64
  (* Test-only fault injection for the rename snapshot regression.  Kept as
     an in-process hook rather than an environment variable so production
     callers cannot accidentally turn a persistence failure on. *)
  let relay_pins_save_hook_for_test : (unit -> unit) option ref = ref None

  let set_relay_pins_save_hook_for_test hook =
    relay_pins_save_hook_for_test := hook

  let downgrade_states : (string, Relay_e2e.downgrade_state) Hashtbl.t = Hashtbl.create 64
  (** Slice B-min-version: per-alias minimum-observed-envelope-version
      pin. Defense-in-depth against MITM envelope_version 2→1 stripping.
      Persisted in [relay_pins.json] under [min_observed_envelope_versions]
      top-level key. Default 1 on first contact (open); monotonic-increase
      via [bump_min_observed_version] after every successful verify. *)
  let min_observed_envelope_versions : (string, int) Hashtbl.t = Hashtbl.create 64
  (** Per-alias rotation-epoch counter. Not persisted — reset on broker
      restart. Operator can re-emit rotate after restart if needed.
      Epoch is incremented on each rotate, allowing the broker to
      distinguish "first contact after intentional rotate" from an
      unexpected first contact (MITM) within a broker lifetime. *)
  let rotation_epochs : (string, int) Hashtbl.t = Hashtbl.create 64

  (** Rehydrate both Hashtbls from disk. Caller MUST hold
      [with_relay_pins_lock].

      #432 TOFU 5 observability follow-up: clear-on-missing-or-malformed.
      Pre-fix [load_section] only cleared the Hashtbl when the
      on-disk JSON contained [Some (`Assoc entries)] for the section,
      so an externally-deleted [relay_pins.json] (or one with a
      missing/malformed section) would leave stale pins in process
      memory while the operator's intent was "wipe pins". The fix
      makes in-memory a true write-through cache of disk: any read
      where the file is missing, the JSON is malformed, or the
      section is absent / empty is treated as "no pins on disk →
      clear in-memory."

      Operator interface: deleting [relay_pins.json] (or rotating
      it via tooling) triggers a clear on the next public-API call
      that goes through the lock. The trade-off is that an external
      delete on a live broker drops in-memory pins, and the next
      [pin_check] for any peer becomes a TOFU first-seen — so this
      is a deliberate operator-rotation interface, not an automatic
      recovery primitive. *)
  let load_relay_pins_from_disk () =
    match !relay_pins_root with
    | None -> ()
    | Some _ ->
      let path = relay_pins_path () in
      if Sys.file_exists path then begin
        (* Slice F + follow-up: check size before parse; emit audit event
           if cap exceeded so operators have observability (fern non-blocking
           note). *)
        let content = C2c_io.read_file_opt path in
        let json =
          if String.length content > 65536 then begin
            (match !relay_pins_root with
             | Some root ->
               log_json_cap_exceeded ~broker_root:root ~path ~max_bytes:65536
             | None -> ());
            `Assoc []
          end else
            (try Yojson.Safe.from_string content with _ -> `Assoc [])
        in
        let load_section name tbl =
          match json with
          | `Assoc fields ->
            (match List.assoc_opt name fields with
             | Some (`Assoc entries) ->
               Hashtbl.clear tbl;
               List.iter (fun (alias, v) ->
                 match v with
                 | `String pk -> Hashtbl.replace tbl alias pk
                 | _ -> ()) entries
             | _ ->
               (* Section absent or malformed → operator wiped this
                  kind on disk. Mirror in memory. *)
               Hashtbl.clear tbl)
          | _ ->
            (* Whole JSON malformed → treat as empty store. *)
            Hashtbl.clear tbl
        in
        load_section "x25519" known_keys_x25519;
        load_section "ed25519" known_keys_ed25519;
        (* Slice B-min-version: int-valued section. Same load-or-clear
           semantics as the string sections above. *)
        (match json with
         | `Assoc fields ->
           (match List.assoc_opt "min_observed_envelope_versions" fields with
            | Some (`Assoc entries) ->
              Hashtbl.clear min_observed_envelope_versions;
              List.iter (fun (alias, v) ->
                match v with
                | `Int n -> Hashtbl.replace min_observed_envelope_versions alias n
                | `Intlit s -> (try Hashtbl.replace min_observed_envelope_versions alias (int_of_string s) with _ -> ())
                | _ -> ()) entries
            | _ -> Hashtbl.clear min_observed_envelope_versions)
         | _ -> Hashtbl.clear min_observed_envelope_versions)
      end else begin
        (* File missing entirely → operator-clear path. Wipe all
           in-memory tables to match the on-disk truth. *)
        Hashtbl.clear known_keys_x25519;
        Hashtbl.clear known_keys_ed25519;
        Hashtbl.clear min_observed_envelope_versions
      end

  (** Serialize both Hashtbls to disk atomically. Caller MUST hold
      [with_relay_pins_lock]. *)
  let save_relay_pins_to_disk () =
    (match !relay_pins_save_hook_for_test with
     | None -> ()
     | Some hook -> hook ());
    match !relay_pins_root with
    | None -> ()
    | Some _ ->
      let dump tbl =
        let entries =
          Hashtbl.fold (fun k v acc -> (k, `String v) :: acc) tbl []
        in
        `Assoc entries
      in
      let dump_int tbl =
        let entries =
          Hashtbl.fold (fun k v acc -> (k, `Int v) :: acc) tbl []
        in
        `Assoc entries
      in
      let json =
        `Assoc
          [ ("x25519", dump known_keys_x25519)
          ; ("ed25519", dump known_keys_ed25519)
          ; ("min_observed_envelope_versions", dump_int min_observed_envelope_versions)
          ]
      in
      write_json_file (relay_pins_path ()) json

  (** Best-effort broker.log audit helpers. Always succeed —
     audit failures never block the mutation path. *)
  let log_relay_pin_delete ~broker_root ~alias ~axes =
    (try
       let path = Filename.concat broker_root "broker.log" in
       let axes_json = `List (List.map (fun a -> `String a) axes) in
       let line =
         `Assoc
           [ ("ts", `Float (Unix.gettimeofday ()))
           ; ("event", `String "relay_pin_delete")
           ; ("alias", `String alias)
           ; ("axes", axes_json)
           ]
         |> Yojson.Safe.to_string
       in
        let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path in
        (try output_string oc (line ^ "\n"); close_out oc
         with _ -> close_out_noerr oc)
      with _ -> ())

  let log_relay_pin_rotate ~broker_root ~alias ~epoch =
    (try
       let path = Filename.concat broker_root "broker.log" in
       let line =
         `Assoc
           [ ("ts", `Float (Unix.gettimeofday ()))
           ; ("event", `String "relay_pin_rotate")
           ; ("alias", `String alias)
           ; ("rotation_epoch", `Int epoch)
           ]
         |> Yojson.Safe.to_string
       in
         let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path in
         (try output_string oc (line ^ "\n"); close_out oc
          with _ -> close_out_noerr oc)
       with _ -> ())

  (** [relay_pin_delete ~broker_root ~alias ~axes] removes the specified
      pin axes for [alias] from the in-memory Hashtbls and persists the
      change to [relay_pins.json]. [axes] is a list containing any subset
      of ["ed25519"; "x25519"; "min_observed_envelope_version"]; an empty
      list is a no-op. Thread-safe via [with_relay_pins_lock]. *)
  let relay_pin_delete ~broker_root ~(alias : string) ~(axes : string list) =
    if axes = [] then () else
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      (if List.mem "ed25519" axes then
         Hashtbl.remove known_keys_ed25519 alias);
      (if List.mem "x25519" axes then
         Hashtbl.remove known_keys_x25519 alias);
      (if List.mem "min_observed_envelope_version" axes then
         Hashtbl.remove min_observed_envelope_versions alias);
      save_relay_pins_to_disk ();
      log_relay_pin_delete ~broker_root ~alias ~axes)

  (** [relay_pin_rotate ~broker_root ~alias] clears all three pin types
      for [alias] and increments the per-alias rotation-epoch counter.
      The epoch is in-memory only (not persisted) — reset on broker restart.
      Emits [relay_pin_rotate] audit event to broker.log. Thread-safe via
      [with_relay_pins_lock]. *)
  let relay_pin_rotate ~broker_root ~(alias : string) =
    let epoch =
      with_relay_pins_lock (fun () ->
        load_relay_pins_from_disk ();
        Hashtbl.remove known_keys_ed25519 alias;
        Hashtbl.remove known_keys_x25519 alias;
        Hashtbl.remove min_observed_envelope_versions alias;
        let new_epoch = 1 + (try Hashtbl.find rotation_epochs alias with Not_found -> 0) in
        Hashtbl.replace rotation_epochs alias new_epoch;
        save_relay_pins_to_disk ();
        new_epoch)
    in
    log_relay_pin_rotate ~broker_root ~alias ~epoch;
    epoch

  let deprecate_canonical_alias_from_env () =
    (* Slice 3 of .collab/design/2026-06-17-c2c-opaque-host-id.md:
       gate the canonical_alias reformatting behind an env var so callers
       can opt into the opaque form without breaking existing consumers. *)
    match Sys.getenv_opt "C2C_DEPRECATE_CANONICAL_ALIAS" with
    | Some v -> v = "1" || String.lowercase_ascii v = "true"
    | None -> false

  let create ~root =
    let deprecate = deprecate_canonical_alias_from_env () in
    let t = { root; deprecate_canonical_alias = deprecate } in
    (* [#432 Slice E] Bind the relay-pins persistence root and load any
       previously-persisted pins into the in-memory Hashtbls. Idempotent
       across recreates within the same process: subsequent [create]
       calls simply re-bind and re-load (which is what tests exercise). *)
    relay_pins_root := Some root;
    (try
       mkdir_p root;
       with_relay_pins_lock (fun () -> load_relay_pins_from_disk ())
     with _ -> ());
    t
  let root t = t.root

  let tofu_mutex : (string, Lwt_mutex.t) Hashtbl.t = Hashtbl.create 64

  let get_tofu_mutex alias =
    match Hashtbl.find_opt tofu_mutex alias with
    | Some m -> m
    | None ->
      let m = Lwt_mutex.create () in
      Hashtbl.add tofu_mutex alias m;
      m

  (* [#432 Slice E] Public read-side accessors load from disk under the
     flock so concurrent broker processes observe each other's pins. The
     in-memory Hashtbl acts as a write-through cache; correctness comes
     from the disk file. *)
  let get_pinned_ed25519 alias =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      Hashtbl.find_opt known_keys_ed25519 alias)
  let set_pinned_ed25519 alias pk =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      Hashtbl.replace known_keys_ed25519 alias pk;
      save_relay_pins_to_disk ())
  let get_pinned_x25519 alias =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      Hashtbl.find_opt known_keys_x25519 alias)
  let set_pinned_x25519 alias pk =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      Hashtbl.replace known_keys_x25519 alias pk;
      save_relay_pins_to_disk ())
  let get_downgrade_state from_alias =
    match Hashtbl.find_opt downgrade_states from_alias with
    | Some ds -> ds
    | None -> Relay_e2e.make_downgrade_state ()
  let set_downgrade_state from_alias ds = Hashtbl.replace downgrade_states from_alias ds

  let pin_x25519_if_unknown ~alias ~pk =
    let m = get_tofu_mutex alias in
    Lwt_mutex.with_lock m (fun () ->
      Lwt.return (with_relay_pins_lock (fun () ->
        load_relay_pins_from_disk ();
        match Hashtbl.find_opt known_keys_x25519 alias with
        | Some existing when existing <> pk -> `Mismatch
        | Some _ -> `Already_pinned
        | None ->
          Hashtbl.replace known_keys_x25519 alias pk;
          save_relay_pins_to_disk ();
          `New_pin)))

  let pin_ed25519_if_unknown ~alias ~pk =
    let m = get_tofu_mutex alias in
    Lwt_mutex.with_lock m (fun () ->
      Lwt.return (with_relay_pins_lock (fun () ->
        load_relay_pins_from_disk ();
        match Hashtbl.find_opt known_keys_ed25519 alias with
        | Some existing when existing <> pk -> `Mismatch
        | Some _ -> `Already_pinned
        | None ->
          Hashtbl.replace known_keys_ed25519 alias pk;
          save_relay_pins_to_disk ();
          `New_pin)))

  let pin_x25519_sync ~alias ~pk =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      match Hashtbl.find_opt known_keys_x25519 alias with
      | Some existing when existing <> pk -> `Mismatch
      | Some _ -> `Already_pinned
      | None ->
        Hashtbl.replace known_keys_x25519 alias pk;
        save_relay_pins_to_disk ();
        `New_pin)

  let pin_ed25519_sync ~alias ~pk =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      match Hashtbl.find_opt known_keys_ed25519 alias with
      | Some existing when existing <> pk -> `Mismatch
      | Some _ -> `Already_pinned
      | None ->
        Hashtbl.replace known_keys_ed25519 alias pk;
        save_relay_pins_to_disk ();
        `New_pin)

  (** Slice B-min-version: expose the broker_root for audit-log emitters
      that don't have a [t] handle. The root is bound by [create] and
      shared with [relay_pins.json] / [broker.log] / etc. *)
  let get_relay_pins_root () = !relay_pins_root

  (** Slice B-min-version read-side accessor. Returns the pinned
      [min_observed_envelope_version] for [alias], or [None] if no pin
      yet (treated as default 1 = open by callers). *)
  let get_min_observed_version alias =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      Hashtbl.find_opt min_observed_envelope_versions alias)

  (** Slice B-min-version max-update on every successful verify.
      Monotonic-increase: [pin <- max(pin, observed)]. Persists via the
      same [save_relay_pins_to_disk] path as the pubkey pins. Returns
      the value AFTER the bump so callers can log the new pin. *)
  let bump_min_observed_version ~alias ~observed =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      let prev_opt = Hashtbl.find_opt min_observed_envelope_versions alias in
      let prev = match prev_opt with Some n -> n | None -> 1 in
      let next = if observed > prev then observed else prev in
      let needs_write =
        match prev_opt with
        | None -> true        (* first-contact pin write, even if observed == default 1 *)
        | Some _ -> next <> prev
      in
      if needs_write then begin
        Hashtbl.replace min_observed_envelope_versions alias next;
        save_relay_pins_to_disk ()
      end;
      next)

  (** Slice B-min-version policy check. [Some pinned_min] when the
      observed [envelope_version] is strictly less than the pinned
      [min_observed_envelope_version] for [alias] (so caller MUST reject
      and emit the audit-log line); [None] otherwise (verify proceeds).
      Default policy when no pin exists for [alias] is "open" (no pin
      → no downgrade defense yet, first-contact records the floor). *)
  let check_version_downgrade ~alias ~observed =
    with_relay_pins_lock (fun () ->
      load_relay_pins_from_disk ();
      match Hashtbl.find_opt min_observed_envelope_versions alias with
      | Some pinned_min when observed < pinned_min -> Some pinned_min
      | _ -> None)

  let load_or_create_ed25519_identity () =
    match Relay_identity.load () with
    | Ok id -> id
    | Error _ ->
      let id = Relay_identity.generate () in
      match Relay_identity.save id with
      | Ok () -> id
      | Error e ->
          (* Save failed (e.g. volume permission denied). Degrade gracefully:
             log clearly, fall back to in-memory identity for this session. *)
          Printf.eprintf "[load_or_create_ed25519_identity] PERMISSION DENIED: cannot persist relay identity: %s\n%!" e;
          Printf.eprintf "[load_or_create_ed25519_identity] Falling back to in-memory identity for this session.\n%!";
          Printf.eprintf "[load_or_create_ed25519_identity] To fix: chmod the broker root and restart.\n%!";
          id

  let write_allowed_signers_entry t ~alias : (unit, string) result =
    let keys_dir = Filename.concat t.root "keys" in
    let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
    let signers_path = Filename.concat t.root "allowed_signers" in
    try
      mkdir_p ~mode:0o700 keys_dir;
      (* Relay_identity.load_or_create_at is called for its side effect (creating
         SSH key files on disk); the returned id is intentionally discarded.
         Audit 2026-04-29 §6 (warning 26 cleanup). *)
      let _id = Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias in
      let ssh_priv_path = priv_path ^ ".ssh" in
      let ssh_pub_path = ssh_priv_path ^ ".pub" in
      if not (Sys.file_exists ssh_pub_path) then
        Error (Printf.sprintf "ssh key not found at %s (run load_or_create_at first)" ssh_pub_path)
      else
        let ic = open_in ssh_pub_path in
        let len = in_channel_length ic in
        let ssh_pub_content = really_input_string ic len in
        close_in ic;
        let b64_key =
          match (let parts = List.filter ((<>) "") (String.split_on_char ' ' ssh_pub_content) in List.nth_opt parts 1) with
          | Some b64 -> Ok (String.trim b64)
          | None -> Error (Printf.sprintf "could not parse ssh pub key from %s" ssh_pub_path)
        in
        match b64_key with
        | Error _ as e -> e
        | Ok b64_key ->
            let date_str = C2c_time.ymd (Unix.time ()) in
            let line = Printf.sprintf "%s@c2c.im ssh-ed25519 %s # added %s\n"
              alias b64_key date_str
            in
            (* 0o644: world-readable SSH authorized_keys-style file, intentionally public. *)
            let oc = open_out_gen [Open_append; Open_creat] 0o644 signers_path in
            Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
              output_string oc line);
            Ok ()
    with e ->
      Error (Printf.sprintf "could not write allowed_signers entry for %s: %s" alias (Printexc.to_string e))

  let registry_lock_path t = Filename.concat t.root "registry.json.lock"

  let with_registry_lock t f =
    ensure_root t;
    let fd =
      Unix.openfile (registry_lock_path t) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  (* Alias-keyed identity material (the relay private keys and TOFU pins) is
     prepared before a caller can commit its registry row.  A registry lock
     alone therefore cannot protect a rename from a concurrent claimant that
     is still constructing the target identity.  Take deterministic,
     case-folded per-alias locks around that preparation and around the
     reversible rename transaction.  The lock file uses a digest rather than
     the alias directly so this remains safe if the alias grammar changes. *)
  let alias_identity_locks_dir t =
    Filename.concat t.root "alias-identity-locks"

  let with_alias_identity_locks t ~aliases f =
    ensure_root t;
    let aliases =
      aliases
      |> List.map alias_casefold
      |> List.sort_uniq String.compare
    in
    let dir = alias_identity_locks_dir t in
    mkdir_p ~mode:0o700 dir;
    let fds = ref [] in
    let release () =
      List.iter
        (fun fd ->
          (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
          (try Unix.close fd with _ -> ()))
        !fds
    in
    (try
       List.iter
         (fun alias ->
           let name = Digest.to_hex (Digest.string alias) ^ ".lock" in
           let fd =
             Unix.openfile (Filename.concat dir name) [ O_RDWR; O_CREAT ] 0o644
           in
           fds := fd :: !fds)
         aliases;
       List.iter (fun fd -> Unix.lockf fd Unix.F_LOCK 0) (List.rev !fds)
     with e ->
       release ();
       raise e);
    Fun.protect ~finally:release f

  (* --- Hardening B: Shell-Launch-Location Guard helpers ------------------- *)

  (* Derive instances_dir using the same logic as C2c_start.instances_dir.
     The expected-cwd file lives at <instances_dir>/<alias>/expected-cwd.
     Broker root is <root>/.git/c2c/mcp, while instances_dir is
     $HOME/.local/share/c2c/instances — different base paths. *)
  let instances_dir () =
    match Sys.getenv_opt "C2C_INSTANCES_DIR" with
    | Some d when String.trim d <> "" -> String.trim d
    | _ ->
        let home =
          try Sys.getenv "HOME" with Not_found -> "/home/" ^ Sys.getenv "USER"
        in
        Filename.concat home (Filename.concat ".local" (Filename.concat "share" (Filename.concat "c2c" "instances")))

  let expected_cwd_path alias =
    Filename.concat (Filename.concat (instances_dir ()) alias) "expected-cwd"

  (** [check_worktree_mismatch t ~from_alias] — Hardening B § Mechanism 2.
      Reads the expected-cwd file for [from_alias] and compares it to the
      sender's cwd stored in the registration. Logs [WORKTREE_MISMATCH] if
      they differ (soft warn only). Coordinator and remote aliases are exempt.
      Returns unit; never raises. *)
  let check_worktree_mismatch t ~from_alias =
    try
      (* Skip for remote aliases (cross-host; cwd is not meaningful) *)
      if String.exists (fun c -> c = '@') from_alias then () else
      (* Skip when C2C_COORDINATOR=1 (coordinator may run from main tree) *)
      if Sys.getenv_opt "C2C_COORDINATOR" = Some "1" then () else
      let expected_path = expected_cwd_path from_alias in
      if not (Sys.file_exists expected_path) then () else
      (* Read expected cwd from file (one line, no trailing newline) *)
      let expected_cwd =
        let ic = open_in expected_path in
        Fun.protect ~finally:(fun () -> close_in ic)
          (fun () ->
             try
               let line = input_line ic in
               String.trim line
             with End_of_file -> "")
      in
      if expected_cwd = "" then () else
      (* Load registrations to get sender's cwd at registration time.
         Acquire the registry lock briefly. *)
      let sender_cwd =
        with_registry_lock t (fun () ->
          let regs = load_registrations t in
          let target = alias_casefold from_alias in
          match List.find_opt (fun reg -> alias_casefold reg.alias = target) regs with
          | Some reg -> reg.cwd
          | None -> None)
      in
      (match sender_cwd with
        | None -> () (* sender not registered — skip *)
        | Some actual_cwd ->
            let key = alias_casefold from_alias in
            if actual_cwd <> expected_cwd then begin
              (* Mismatch: log + update state to true *)
              (try
                 let ts = Unix.gettimeofday () in
                 let fields =
                   [ ("ts", `Float ts)
                   ; ("event", `String "worktree_mismatch")
                   ; ("alias", `String from_alias)
                   ; ("expected_cwd", `String expected_cwd)
                   ; ("actual_cwd", `String actual_cwd)
                   ]
                 in
                 log_broker_event ~broker_root:(root t) "WORKTREE_MISMATCH" fields
               with _ -> ());
              Hashtbl.replace prior_mismatch_state key true
            end else
              (* Match: only log if prior state was mismatch (transition) *)
              (match Hashtbl.find_opt prior_mismatch_state key with
               | Some true ->
                   (* Transition mismatch→match: log recovery + update state *)
                   (try
                      let ts = Unix.gettimeofday () in
                      let fields =
                        [ ("ts", `Float ts)
                        ; ("event", `String "worktree_match")
                        ; ("alias", `String from_alias)
                        ; ("cwd", `String expected_cwd)
                        ]
                      in
                      log_broker_event ~broker_root:(root t) "WORKTREE_MATCH" fields
                    with _ -> ());
                   Hashtbl.replace prior_mismatch_state key false
               | _ -> ()))
    with _ -> ()

  let list_registrations t =
    load_registrations t
    |> List.filter (fun reg -> not (is_expired_codex_hook_auto_registration reg))

  (* B135: alias is sticky per session_id. Explicit rename of an existing
     registration is refused — start a fresh session for a new name.
     Same-alias re-register (PID refresh) remains allowed. Comparison is
     case-insensitive (alias_casefold). Low-level [register] still updates
     in-place for same-session alias changes; policy is enforced at the
     MCP register handler and CLI init/register surfaces. *)
  let sticky_alias_conflict t ~session_id ~requested_alias =
    match
      List.find_opt
        (fun reg -> reg.session_id = session_id)
        (list_registrations t)
    with
    | Some reg
      when alias_casefold reg.alias <> alias_casefold requested_alias ->
        Some reg.alias
    | _ -> None

  let sticky_alias_error ~session_id ~existing_alias ~requested_alias =
    Printf.sprintf
      "register rejected: alias is sticky for session_id '%s' (currently '%s'). \
       You requested '%s'. Start a fresh session to use a new name; \
       same-alias re-register remains allowed for PID refresh. \
       To deliberately rename this session everywhere, run: c2c rename %s"
      session_id existing_alias requested_alias requested_alias

  (* /proc/<pid>/stat line layout: "<pid> (<comm>) <state> <ppid> ... <starttime> ..."
     comm can contain spaces and parens, so we split on the LAST ')'. The fields
     after comm are space-separated; starttime is field 22 in the 1-indexed man
     page, which is index 19 in the 0-indexed tail array (tail[0] = state). *)
  let read_pid_start_time pid =
    let path = Printf.sprintf "/proc/%d/stat" pid in
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = input_line ic in
          match String.rindex_opt line ')' with
          | None -> None
          | Some idx ->
              let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
              let parts = String.split_on_char ' ' tail in
              (match List.nth_opt parts 19 with
               | Some token ->
                   (try Some (int_of_string token) with _ -> None)
               | None -> None))
    with Sys_error _ | End_of_file -> None

  let capture_pid_start_time pid =
    match pid with
    | None -> None
    | Some n -> read_pid_start_time n

  (* Read /proc/<pid>/environ as a list of (key, value) pairs. Environ
     entries are NUL-separated KEY=VALUE strings. Returns None on any
     IO error (e.g. permission denied for processes owned by other
     users, or pid is gone). *)
  let read_proc_environ pid =
    let path = Printf.sprintf "/proc/%d/environ" pid in
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let buf = Buffer.create 4096 in
          (try
             while true do
               Buffer.add_channel buf ic 4096
             done
           with End_of_file -> ());
          let raw = Buffer.contents buf in
          let entries = String.split_on_char '\x00' raw in
          let pairs =
            List.filter_map
              (fun e ->
                if e = "" then None
                else
                  match String.index_opt e '=' with
                  | None -> None
                  | Some i ->
                      let k = String.sub e 0 i in
                      let v = String.sub e (i + 1) (String.length e - i - 1) in
                      Some (k, v))
              entries
          in
          Some pairs)
    with Sys_error _ | End_of_file -> None

  (* Default scanner: every numeric entry in /proc is a pid. *)
  let default_scan_pids () =
    try
      let dh = Unix.opendir "/proc" in
      Fun.protect
        ~finally:(fun () -> try Unix.closedir dh with _ -> ())
        (fun () ->
          let acc = ref [] in
          (try
             while true do
               let name = Unix.readdir dh in
               match int_of_string_opt name with
               | Some pid when pid > 0 -> acc := pid :: !acc
               | _ -> ()
             done
           with End_of_file -> ());
          !acc)
    with _ -> []

  (* Discover the live pid for a given C2C_MCP_SESSION_ID by scanning
     /proc/*/environ. Used when an existing registration's pid is dead
     but the session is in fact still alive under a new pid (e.g. an
     opencode TUI respawn that does not also restart the MCP-launching
     wrapper).

     [scan_pids] and [read_environ] are injectable for tests; defaults
     scan real /proc. Returns the FIRST matching pid. If multiple
     processes claim the same session_id, that's a separate bug; we
     return the first to keep this function deterministic for tests. *)
  let discover_live_pid_for_session_with
      ~scan_pids ~read_environ ~session_id =
    let candidates = scan_pids () in
    let candidates = List.sort compare candidates in
    List.find_map
      (fun pid ->
        match read_environ pid with
        | None -> None
        | Some env ->
            (match List.assoc_opt "C2C_MCP_SESSION_ID" env with
             | Some sid when sid = session_id -> Some pid
             | _ -> None))
      candidates

  let effective_scan_pids () =
    match !proc_scan_pids_override with
    | Some f -> f ()
    | None -> default_scan_pids

  let effective_read_environ () =
    match !proc_read_environ_override with
    | Some f -> f ()
    | None -> read_proc_environ

  let discover_live_pid_for_session ~session_id =
    discover_live_pid_for_session_with
      ~scan_pids:(effective_scan_pids ())
      ~read_environ:(effective_read_environ ())
      ~session_id

  (* ---------------------------------------------------------------- *)
  (* B071: stable client pid discovery.                                 *)
  (*                                                                    *)
  (* `c2c register` used to fall back to Unix.getppid (), but from an   *)
  (* agent-harness shell (Claude Bash tool, codex shell) the parent is  *)
  (* a transient per-command shell that dies immediately — the          *)
  (* registration is born dead and send-side alias resolution refuses   *)
  (* to route to it. Instead, walk /proc ancestry from the parent       *)
  (* upward and pin liveness to the first ancestor that identifies as   *)
  (* a known long-lived agent process. If none is found, callers        *)
  (* should register pid=None (unknown liveness — which IS routable).   *)
  (*                                                                    *)
  (* [proc_root] is injectable so tests can fake /proc with a temp dir. *)
  (* ---------------------------------------------------------------- *)

  (** Names that identify a long-lived agent host process. Matched as an
      exact path COMPONENT of argv[0] or argv[1] (leading tokens only) or
      as the exact /proc comm — never substring-anywhere, so a script named
      `codex-c2c-live-test.sh` does not match. Component matching (not just
      basename) is required because real installs run versioned binaries,
      e.g. Claude Code is `~/.local/share/claude/versions/2.1.201` (comm
      "2.1.201") — the "claude" signal only survives in the path. *)
  let known_agent_process_tokens =
    [ "claude"; "claude-code"; "codex"; "kimi"; "opencode"; "pi"
    ; "crush" ]

  (** Parent pid from /proc/<pid>/stat — field 4 (index 1 of the tail
      after the last ')', same parsing discipline as read_pid_start_time). *)
  let read_pid_ppid ?(proc_root = "/proc") pid =
    let path = Printf.sprintf "%s/%d/stat" proc_root pid in
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = input_line ic in
          match String.rindex_opt line ')' with
          | None -> None
          | Some idx ->
              let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
              let parts = String.split_on_char ' ' tail in
              (match List.nth_opt parts 1 with
               | Some token -> int_of_string_opt token
               | None -> None))
    with Sys_error _ | End_of_file -> None

  (** argv of /proc/<pid>/cmdline (NUL-separated). [] on any error. *)
  let read_pid_cmdline ?(proc_root = "/proc") pid =
    let path = Printf.sprintf "%s/%d/cmdline" proc_root pid in
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let buf = Buffer.create 256 in
          (try
             while true do
               Buffer.add_channel buf ic 256
             done
           with End_of_file -> ());
          Buffer.contents buf
          |> String.split_on_char '\x00'
          |> List.filter (fun s -> s <> ""))
    with Sys_error _ | End_of_file -> []

  let read_pid_comm ?(proc_root = "/proc") pid =
    let path = Printf.sprintf "%s/%d/comm" proc_root pid in
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () -> Some (String.trim (input_line ic)))
    with Sys_error _ | End_of_file -> None

  (** True when /proc/<pid> identifies a known long-lived agent process.
      Exact path-COMPONENT match on argv[0]/argv[1] or exact comm match —
      never substring-anywhere, so `codex-c2c-live-test.sh` cannot match.
      Component (not just basename) matching is load-bearing: the real
      Claude Code binary is `~/.local/share/claude/versions/2.1.201`, so
      both its basename and comm are the bare version string. *)
  let pid_is_known_agent ?proc_root pid =
    let token_matches_path s =
      String.split_on_char '/' s
      |> List.exists (fun comp ->
             List.mem (String.lowercase_ascii comp) known_agent_process_tokens)
    in
    let argv = read_pid_cmdline ?proc_root pid in
    (match argv with
     | a0 :: rest ->
         token_matches_path a0
         || (match rest with a1 :: _ -> token_matches_path a1 | [] -> false)
     | [] -> false)
    || (match read_pid_comm ?proc_root pid with
        | Some c -> List.mem (String.lowercase_ascii c) known_agent_process_tokens
        | None -> false)

  (** True when some environ VALUE of /proc/<pid> equals [value] exactly
      (e.g. CLAUDE_SESSION_ID=<sid>). Environ reads fail cleanly for
      other-uid processes — treated as no-match. *)
  let proc_environ_has_value ?(proc_root = "/proc") pid value =
    let path = Printf.sprintf "%s/%d/environ" proc_root pid in
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let buf = Buffer.create 4096 in
          (try
             while true do
               Buffer.add_channel buf ic 4096
             done
           with End_of_file -> ());
          Buffer.contents buf
          |> String.split_on_char '\x00'
          |> List.exists (fun entry ->
                 match String.index_opt entry '=' with
                 | None -> false
                 | Some i ->
                     String.sub entry (i + 1) (String.length entry - i - 1)
                     = value))
    with Sys_error _ | End_of_file -> false

  (** Walk /proc ancestry from [start_pid] (default: getppid) upward, at
      most [max_hops] hops, and return the first ancestor that identifies
      as a known agent process. When [session_id] is given, an ancestor
      whose cmdline matches AND whose environ carries that session id is
      the strong signal and returned immediately; a cmdline-only match is
      kept as fallback. Returns None when no ancestor matches — callers
      should then register pid=None (unknown liveness, routable) rather
      than a doomed transient pid. *)
  let stable_client_pid ?(proc_root = "/proc") ?(max_hops = 15) ?session_id
      ?start_pid () =
    let start =
      match start_pid with Some p -> p | None -> Unix.getppid ()
    in
    let environ_confirms pid =
      match session_id with
      | None -> false
      | Some sid ->
          String.trim sid <> ""
          && proc_environ_has_value ~proc_root pid (String.trim sid)
    in
    let rec walk pid hops weak =
      if pid <= 1 || hops > max_hops then weak
      else begin
        let is_agent = pid_is_known_agent ~proc_root pid in
        if is_agent && environ_confirms pid then Some pid
        else
          let weak =
            match weak with
            | Some _ -> weak
            | None -> if is_agent then Some pid else None
          in
          match read_pid_ppid ~proc_root pid with
          | Some ppid when ppid <> pid && ppid > 0 -> walk ppid (hops + 1) weak
          | _ -> weak
      end
    in
    walk start 0 None

  (* Docker-in-Docker liveness: when C2C_IN_DOCKER=1 is set (e.g. in
     docker-compose test containers), PID namespaces are isolated — a
     process in container A cannot see /proc/<pid> of a process in
     container B even when they share a volume. Instead, each session
     touches a lease file in the shared broker root; registration_is_alive
     checks whether that file has been modified within the TTL window.
     All containers sharing the same broker root volume see the same
     lease files, so cross-container liveness is visible. *)
  let docker_lease_ttl = 300.0  (* seconds: 5 min, covers test duration + GC headroom *)

  let docker_lease_dir_name = ".leases"

  let lease_file_path t ~session_id =
    Filename.concat (Filename.concat t.root docker_lease_dir_name) session_id

  (* Ensure the .leases directory exists; errors are swallowed — touch_lease
     is best-effort and must never block registration or delivery. *)
  let ensure_lease_dir t =
    let dir = Filename.concat t.root docker_lease_dir_name in
    if not (Sys.file_exists dir) then
      mkdir_p ~mode:0o755 dir

  (* Touch the lease file for session_id, creating it if absent.
     Called on every broker interaction via touch_session so the mtime
     advances whenever the session is alive. Errors swallowed. *)
  let touch_lease t ~session_id =
    try
      ensure_lease_dir t;
      let path = lease_file_path t ~session_id in
      (* Use open+O_CREAT to create the file atomically if absent, then utimes to set mtime *)
      let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_NOCTTY; Unix.O_NONBLOCK; Unix.O_WRONLY] 0o644 in
      Unix.close fd;
      Unix.utimes path 0.0 (Unix.gettimeofday ())
    with Unix.Unix_error _ -> ()

  let docker_broker_root () : (string, string) result =
    match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
    | Some root when String.trim root <> "" -> Ok (String.trim root)
    | _ -> Error "C2C_IN_DOCKER=1 requires C2C_MCP_BROKER_ROOT to be set"

  let in_docker_mode () =
    match Sys.getenv_opt "C2C_IN_DOCKER" with
    | Some "1" | Some "true" | Some "yes" -> true
    | _ -> false

  let registration_is_alive reg =
    (* When Docker mode is active, use the file-based lease instead of
       /proc/<pid> checks. The lease is touched on every touch_session
       call, so a recent mtime means the session is alive in its container. *)
     if in_docker_mode () then
       match reg.pid with
       | None -> true
       | Some _pid ->
           match docker_broker_root () with
           | Error _ -> true  (* env misconfigured: assume alive rather than false dead *)
           | Ok root ->
               let path = lease_file_path { root; deprecate_canonical_alias = false } ~session_id:reg.session_id in
               if not (Sys.file_exists path) then false
               else
                 (try
                   let stat = Unix.stat path in
                   let age = Unix.gettimeofday () -. stat.st_mtime in
                   age <= docker_lease_ttl
                  with Unix.Unix_error _ -> false)
    else
      match reg.pid with
      | None -> true
      | Some pid ->
          if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then false
          else
            (match reg.pid_start_time with
             | None -> true
             | Some stored ->
                 (match read_pid_start_time pid with
                  | Some current -> current = stored
                  | None -> false))

  (* Tristate liveness for the list tool: distinguishes "we cannot
     tell" (legacy pidless row) from "we checked and the kernel says
     alive" / "we checked and the pid is dead or pid-reused". The
     legacy `registration_is_alive` collapses Unknown into Alive for
     backward-compat with sweep / enqueue, but operators consuming
     the list tool benefit from seeing the unknown case explicitly so
     they can identify pidless zombie rows. *)
  type liveness_state = Alive | Dead | Unknown

  let registration_liveness_state reg =
    (* Vanilla Codex sessions are registered by short-lived hooks, so they
       deliberately have no stable process PID to inspect.  Their bounded
       hook-activity lease is nevertheless the delivery signal: while it is
       fresh the next Codex hook can drain a queued message.  Do not leave
       these peers as [Unknown] in discovery output when we have that signal. *)
    if is_codex_hook_auto_registration reg && reg.pid = None then
      match codex_hook_activity_anchor reg with
      | Some ts
        when Unix.gettimeofday () -. ts <= codex_hook_auto_registration_ttl_s ->
          Alive
      | Some _ -> Dead
      | None -> Unknown
    else
    if in_docker_mode () then
      match reg.pid with
      | None -> Unknown
      | Some _pid ->
          match docker_broker_root () with
          | Error _ -> Unknown  (* env misconfigured: cannot determine *)
          | Ok root ->
              let path = lease_file_path { root; deprecate_canonical_alias = false } ~session_id:reg.session_id in
              if not (Sys.file_exists path) then Unknown
              else
                (try
                  let stat = Unix.stat path in
                  let age = Unix.gettimeofday () -. stat.st_mtime in
                  if age <= docker_lease_ttl then Alive else Dead
                 with Unix.Unix_error _ -> Unknown)
    else
      match reg.pid with
      | None -> Unknown
      | Some pid ->
          if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then Dead
          else
            (match reg.pid_start_time with
             | None -> Unknown
             | Some stored ->
                 (match read_pid_start_time pid with
                  | Some current -> if current = stored then Alive else Dead
                  | None -> Dead))

  type resolve_result =
    | Resolved of string
    | Unknown_alias
    | All_recipients_dead

  (* Refresh a registration's pid + pid_start_time when the stored pid
     is dead but a live process exists for the same session_id (e.g.
     opencode TUI respawned under a new pid without restarting its
     MCP-launching wrapper). The discovery is gated on
     [scan_pids]/[read_environ] so tests can simulate /proc.

     Returns true if a refresh happened, false otherwise. Only fires
     when:
       - the registration exists
       - its pid is non-None and Dead per registration_is_alive
       - discovery finds a different live pid claiming the same
         C2C_MCP_SESSION_ID
     A no-op for healthy regs, missing regs, or pidless legacy rows. *)
  let refresh_pid_if_dead_with
      ~scan_pids ~read_environ t ~session_id =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun reg -> reg.session_id = session_id) regs with
      | None -> false
      | Some reg ->
          (match reg.pid with
           | None -> false
            | Some _ when registration_is_alive reg -> false
           | Some old_pid ->
               (match discover_live_pid_for_session_with
                        ~scan_pids ~read_environ ~session_id with
                | None -> false
                | Some new_pid when new_pid = old_pid ->
                    (* same pid, just dead — discovery couldn't find a
                       live replacement. Don't update. *)
                    false
                | Some new_pid ->
                    let new_start = read_pid_start_time new_pid in
                    let regs' =
                      List.map
                        (fun r ->
                          if r.session_id = session_id
                          then { r with pid = Some new_pid; pid_start_time = new_start }
                          else r)
                        regs
                    in
                    save_registrations t regs';
                    true)))

  let refresh_pid_if_dead t ~session_id =
    refresh_pid_if_dead_with
      ~scan_pids:(effective_scan_pids ())
      ~read_environ:(effective_read_environ ())
      t ~session_id

  let resolve_live_session_id_by_alias t alias =
    (* #432: case-insensitive alias match. Mirrors the eviction predicate
       at register-time (see [alias_casefold] usage at L1572) so a stale
       row whose alias differs from [alias] only in case is found by both
       resolver lookups AND eviction sweeps. Without this symmetry, the
       pid-refresh self-heal below could resurrect a stale row that the
       new register would have evicted. *)
    let target = alias_casefold alias in
    let matches =
      load_registrations t
      |> List.filter (fun reg ->
        alias_casefold reg.alias = target
        && not (is_expired_codex_hook_auto_registration reg))
    in
    (* #432: silent multi-match on alive rows is the smoking gun for the
       galaxy-coder-style misdelivery. Log it so the next investigator
       has a breadcrumb. *)
    let alive_count =
      List.fold_left
        (fun acc r -> if registration_is_alive r then acc + 1 else acc)
        0 matches
    in
    if alive_count > 1 then begin
      try
        let path = Filename.concat t.root "broker.log" in
        let ts = Unix.gettimeofday () in
        let line =
          `Assoc
            [ ("ts", `Float ts)
            ; ("event", `String "alias_resolve_multi_match")
            ; ("alias", `String alias)
            ; ("alive_count", `Int alive_count)
            ; ("total_matches", `Int (List.length matches))
            ]
          |> Yojson.Safe.to_string
        in
        C2c_io.append_jsonl path line
      with _ -> ()
    end;
    match matches with
    | [] ->
        if debug_enabled then Printf.eprintf "[DEBUG resolve] alias=%s -> Unknown_alias (no matches)\n%!" alias;
        Unknown_alias
    | _ ->
        let alive_reg = List.find_opt registration_is_alive matches in
        (match alive_reg with
         | Some reg ->
             if debug_enabled then Printf.eprintf "[DEBUG resolve] alias=%s -> Resolved %s (alive)\n%!" alias reg.session_id;
             Resolved reg.session_id
         | None ->
             (* Target-side self-heal: every match looks dead, but the
                target may have respawned under a new pid without
                touching the broker yet. Try to refresh each candidate
                via /proc scan; if any flips to Alive, return that.
                Without this, a sender to e.g. galaxy-coder hits
                All_recipients_dead even when galaxy is live under a
                fresh pid — the bug this slice exists to fix. *)
             let healed =
               List.fold_left
                 (fun acc reg ->
                   match acc with
                   | Some _ -> acc
                   | None ->
                       if refresh_pid_if_dead t ~session_id:reg.session_id
                       then begin
                         (* Re-load to pick up the swapped pid; the in-memory
                            [reg] is stale after refresh. *)
                         let regs' = load_registrations t in
                         List.find_opt
                           (fun r -> r.session_id = reg.session_id
                                  && registration_is_alive r)
                           regs'
                       end else None)
                 None matches
             in
             (match healed with
              | Some reg ->
                  if debug_enabled then Printf.eprintf "[DEBUG resolve] alias=%s -> Resolved %s (healed)\n%!" alias reg.session_id;
                  Resolved reg.session_id
              | None ->
                  if debug_enabled then Printf.eprintf "[DEBUG resolve] alias=%s -> All_recipients_dead (matches=%d, none alive per lease/proc, heal failed)\n%!"
                    alias (List.length matches);
                  All_recipients_dead))

  (* A provisional registration has no confirmed PID-based liveness yet AND
     has never drained its inbox (confirmed_at = None). Human sessions are
     exempt. Provisional sessions with no PID are eligible for sweep after
     C2C_PROVISIONAL_SWEEP_TIMEOUT seconds (default 1800). *)
  let is_provisional reg =
    match reg.client_type with
    | Some "human" -> false
    | _ ->
        reg.pid = None && reg.confirmed_at = None

  (* True for any non-human session that has never called poll_inbox (confirmed_at=None).
     Used to gate noisy social broadcasts (peer_register, room-join) so they fire
     only when a session is confirmed alive, not speculatively on startup.
     Broader than is_provisional: includes sessions that have a PID but haven't
     polled yet (e.g. opencode started via c2c start but not yet interactive). *)
  let is_unconfirmed reg =
    match reg.client_type with
    | Some "human" -> false
    | _ -> reg.confirmed_at = None

  let provisional_sweep_timeout () =
    match Sys.getenv_opt "C2C_PROVISIONAL_SWEEP_TIMEOUT" with
    | Some v -> (try float_of_string v with _ -> 1800.0)
    | None -> 1800.0

  let is_provisional_expired reg =
    if not (is_provisional reg) then false
    else
      match reg.registered_at with
      | None -> false  (* legacy rows predate registered_at — never provisional-expired *)
      | Some ra ->
          Unix.gettimeofday () -. ra > provisional_sweep_timeout ()

  (* Sweep-only predicate (#344): stricter than [registration_is_alive] for
     pidless rows, which the canonical liveness check collapses into Alive
     for backward-compat with sweep/enqueue. The audit
     (.collab/findings/2026-04-28T04-25-00Z-stanza-coder-pidless-zombie-systemic-audit.md
     Finding 1) showed that pidless rows that ever drained, or pre-
     registered_at legacy rows, are structurally un-reapable. This
     predicate distinguishes:
       - PID-tracked: existing alive + provisional logic.
       - Pidless human: exempt (humans aren't zombies).
       - Pidless legacy (registered_at=None): no anchor — treat as
         zombie, drop it.
       - Pidless unconfirmed (confirmed_at=None): provisional window
         applies (default 1800s).
       - Pidless confirmed: only kept for a brief handoff window
         (pidless_keep_window_s, 1h) — long enough to cover daemon
         restart transients but bounded so true zombies are reaped.
     [registration_is_alive] is intentionally unchanged so enqueue
     and resolve paths keep their lenient semantics. *)
  let pidless_keep_window_s = 3600.0

  let is_sweep_keepable reg =
    if
      is_codex_hook_auto_registration reg
      && reg.pid = None
    then not (is_expired_codex_hook_auto_registration reg)
    else
    match reg.pid with
    | Some _ ->
        registration_is_alive reg && not (is_provisional_expired reg)
    | None ->
        if reg.client_type = Some "human" then true
        else
          (match reg.registered_at with
           | None -> false  (* legacy — no anchor, treat as zombie *)
           | Some ts ->
               let age = Unix.gettimeofday () -. ts in
               if reg.confirmed_at = None then
                 age < provisional_sweep_timeout ()
               else
                 age < pidless_keep_window_s)

  (* H9: emit a structured `inbox_row_skipped` line in broker.log whenever
     [load_inbox] drops a row that [message_of_json] rejects. Best-effort:
     any failure is swallowed — logging must never block an inbox read.
     The row is embedded as a (truncated) string, not verbatim JSON, so a
     hostile row can't shape the log entry itself. *)
  let log_inbox_row_skipped t ~session_id ~row =
    (try
       let row_str = Yojson.Safe.to_string row in
       let row_sample =
         if String.length row_str > 256 then String.sub row_str 0 256 ^ "..."
         else row_str
       in
       log_broker_event ~broker_root:t.root "inbox_row_skipped"
         [ ("ts", `Float (Unix.gettimeofday ()))
         ; ("session_id", `String session_id)
         ; ("row", `String row_sample)
         ]
     with _ -> ())

  let load_inbox t ~session_id =
    ensure_root t;
    let path = inbox_path t ~session_id in
    let result =
      match read_json_file ~broker_root:t.root path ~default:(`List []) with
      | `List items ->
          (* H9 defense-in-depth: total PER-ROW. A row that fails
             [message_of_json] (e.g. written by a pre-H9 relay connector
             from a schema-garbage /poll_inbox response, or any buggy/
             foreign writer) is skipped + logged instead of raising
             Yojson Type_error through the whole read — one poisoned row
             used to wedge every broker-side inbox read for the session.
             Read-only healing: the file itself is left as-is; the next
             drain/save rewrites it from parsed rows, dropping the bad
             ones permanently. *)
          List.filter_map
            (fun item ->
              match message_of_json item with
              | msg -> Some msg
              | exception _ ->
                  log_inbox_row_skipped t ~session_id ~row:item;
                  None)
            items
      | _ -> []
    in
    if debug_enabled then Printf.eprintf "[DEBUG load_inbox] session_id=%s path=%s msgs=%d\n%!"
      session_id path (List.length result);
    result

  let save_inbox t ~session_id messages =
    ensure_root t;
    let path = inbox_path t ~session_id in
    if debug_enabled then Printf.eprintf "[DEBUG save_inbox] session_id=%s path=%s msgs=%d\n%!"
      session_id path (List.length messages);
    write_json_file path (`List (List.map message_to_json messages))

  let inbox_lock_path t ~session_id =
    Filename.concat t.root (session_id ^ ".inbox.lock")

  (* POSIX fcntl-based exclusive lock via Unix.lockf on a sidecar file, so
     concurrent enqueue/drain/sweep don't clobber each other's read-modify-
     write window. Compatible with Python fcntl.lockf on the same sidecar,
     which matters for c2c_send.py's broker-only fallback path. *)
  let with_inbox_lock t ~session_id f =
    ensure_root t;
    let fd =
      Unix.openfile (inbox_lock_path t ~session_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  (** Inspect whether an inbox still has a message eligible for push delivery.
      Callers that need to compose this check with other inbox operations must
      hold [with_inbox_lock] for the same [t]/[session_id]. *)
  let inbox_has_push_messages_locked t ~session_id =
    load_inbox t ~session_id
    |> List.exists (fun (m : message) -> not m.deferrable)

  (* register, enqueue_message, and send_all all take the registry lock
     before touching inbox state. Lock order is consistently
     registry → inbox (matches sweep). Without this, a sender that resolved
     the registry snapshot before a re-register can write to a now-orphan
     inbox file because resolution is unsynchronized with eviction. *)

  let reserved_system_aliases = ["c2c"; "c2c-system"]

  let is_reserved_system_alias alias =
    let folded = alias_casefold alias in
    List.exists
      (fun reserved -> alias_casefold reserved = folded)
      reserved_system_aliases

  (* --- alias blocklist (user-supplied names only) ----------------------------- *)

  let banned_aliases = C2c_blocklist.banned_aliases

  let is_banned_alias = C2c_blocklist.is_banned_alias

  (* --- canonical alias helpers ----------------------------------------------- *)

  (* Derive repo slug from broker_root path:
     broker_root = .../repo/.git/c2c/mcp → "repo" *)
  let repo_slug_of_broker_root broker_root =
    try
      let git_dir = Filename.dirname (Filename.dirname broker_root) in
      let repo_root = Filename.dirname git_dir in
      let slug = Filename.basename repo_root in
      if slug = "" || slug = "." || slug = "/" then "unknown" else slug
    with _ -> "unknown"

  let short_hostname () =
    try
      let h = Unix.gethostname () in
      match String.split_on_char '.' h with
      | s :: _ when s <> "" -> s
      | _ -> h
    with _ -> "unknown"

  let compute_canonical_alias ?(deprecate_canonical_alias = false) ~alias ~broker_root () =
    if deprecate_canonical_alias then
      (* Slice 3 of .collab/design/2026-06-17-c2c-opaque-host-id.md:
         replace the leaky <repo-slug>@<hostname> suffix with the opaque
         host id computed by Host_id.compute_host_hash. *)
      Printf.sprintf "%s#%s" alias (Host_id.compute_host_hash ())
    else
      Printf.sprintf "%s#%s@%s" alias
        (repo_slug_of_broker_root broker_root)
        (short_hostname ())

  (* Primes for alias disambiguation *)
  let small_primes = [| 2; 3; 5; 7; 11; 13; 17; 19; 23; 29; 31; 37; 41; 43; 47 |]

  let next_prime_after n =
    let is_prime p =
      if p < 2 then false
      else
        let rec check d = d * d > p || (p mod d <> 0 && check (d + 1)) in
        check 2
    in
    let rec find p = if is_prime p then p else find (p + 1) in
    find (n + 1)

  (** Returns [true] iff the registration for [session_id] has its
      [automated_delivery] flag set to [Some true]. Used by the PostToolUse
      inbox hook to skip its drain when the MCP server's channel watcher
      will own delivery (#387 A2). Missing registration or [None] flag =>
      [false] (treat as not channel-capable, fall through to drain). *)
  let is_session_channel_capable t ~session_id =
    match
      List.find_opt
        (fun r -> r.session_id = session_id)
        (list_registrations t)
    with
    | None -> false
    | Some r ->
        (match r.automated_delivery with
         | Some true -> true
         | _ -> false)

  (** Check whether *session_id* is currently in DND mode (considering auto-expire). *)
  let is_dnd t ~session_id =
    let now = Unix.gettimeofday () in
    match List.find_opt (fun r -> r.session_id = session_id) (list_registrations t) with
    | None -> false
    | Some r ->
        if not r.dnd then false
        else begin
          (* Auto-expire check: if dnd_until is set and has passed, DND is cleared. *)
          match r.dnd_until with
          | Some until when now >= until -> false
          | _ -> true
        end

  (** Set or clear DND for *session_id*. Returns the new dnd state, or None if
      the session is not registered. When [until] is given, DND auto-expires at
      that epoch. [until = None] means no auto-expire (manual off only). *)
  let set_dnd t ~session_id ~dnd ?until () =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> None
      | Some existing ->
          let now = Unix.gettimeofday () in
          let updated = { existing with
            dnd
          ; dnd_since = (if dnd then Some now else None)
          ; dnd_until  = (if dnd then until else None)
          } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          Some dnd)

  let compacting_stale_after = 300.0

  let is_compacting t ~session_id =
    let now = Unix.gettimeofday () in
    match List.find_opt (fun r -> r.session_id = session_id) (list_registrations t) with
    | None -> None
    | Some r ->
        match r.compacting with
        | None -> None
        | Some c ->
            if now -. c.started_at > compacting_stale_after then None
            else Some c

  let set_compacting t ~session_id ?reason () =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> None
      | Some existing ->
          let now = Unix.gettimeofday () in
          let updated = { existing with compacting = Some { started_at = now; reason } } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          Some { started_at = now; reason })

  let clear_compacting t ~session_id =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> false
      | Some existing ->
          let updated = { existing with compacting = None
                        ; compaction_count = existing.compaction_count + 1 } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          true)

  let clear_stale_compacting t =
    let now = Unix.gettimeofday () in
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let to_clear, to_keep =
        List.partition (fun r ->
          match r.compacting with
          | None -> false
          | Some c -> now -. c.started_at > compacting_stale_after) regs
      in
      if to_clear = [] then 0
      else begin
        let cleared = List.map (fun r -> { r with compacting = None
                                         ; compaction_count = r.compaction_count + 1 }) to_clear in
        save_registrations t (cleared @ to_keep);
        List.length cleared
      end)

  (* [alias_casefold] hoisted to top of Broker module — see definition
     above [load_registrations] (#432 follow-up by stanza-coder). *)

  (* Suggest a free alias by appending the next prime suffix.
     Case-insensitive: colliding with a case-variant gets a prime suffix. *)
  let suggest_alias_prime ?(max_tries = 5) regs ~base_alias =
    let alive = List.filter_map (fun reg ->
      if registration_is_alive reg then Some (alias_casefold reg.alias) else None) regs in
    let base = alias_casefold base_alias in
    if not (List.mem base alive) then Some base_alias
    else begin
      let n = Array.length small_primes in
      let rec try_idx i =
        if i >= max_tries then None
        else begin
          let p =
            if i < n then small_primes.(i)
            else next_prime_after small_primes.(n - 1)
          in
          let candidate = Printf.sprintf "%s-%d" base p in
          if not (List.mem candidate alive) then Some candidate
          else try_idx (i + 1)
        end
      in
      try_idx 0
    end

  (* Public wrapper: reads registry and suggests disambiguated alias.
     Returns Some alias on success, None when ALIAS_COLLISION_EXHAUSTED. *)
  let suggest_alias_for_alias t ~alias =
    with_registry_lock t (fun () ->
      suggest_alias_prime (load_registrations t) ~base_alias:alias)

  let register t ~session_id ~alias ~pid ~pid_start_time ?(client_type = None) ?(plugin_version = None) ?(enc_pubkey = None) ?(ed25519_pubkey = None) ?(pubkey_signed_at = None) ?(pubkey_sig = None) ?(role = None) ?(tmux_location = None) ?(herdr_pane = None) ?(herdr_socket = None) ?(cwd = None) ?(metadata_opt_out = false) ?(registered_by = None) ?(opaque_host_id = None) ?(from_auto_gen = false) () =
    if is_reserved_system_alias alias then
      invalid_arg (Printf.sprintf
        "register rejected: '%s' is a reserved system alias" alias);
    if (not from_auto_gen) && is_banned_alias alias then
      invalid_arg (C2c_blocklist.blocked_alias_error alias);
    if not (C2c_name.is_valid alias) then
      invalid_arg (Printf.sprintf "register rejected: %s"
        (C2c_name.error_message "alias" alias));
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        (* Registry → pending is the canonical multi-store order.  Keep the
           pending lock through [save_registrations], not merely through the
           observation, so a newly-opened prior-owner permission cannot slip
           between this check and the claimant commit. *)
        with_pending_lock t (fun () ->
        (* The handler performs friendly preflight checks before it creates
           alias-keyed keys and pins, but another claimant may commit while
           that work is in flight.  Revalidate the ownership and M4 pending
           guards at this registry commit point before evicting anything. *)
        let target = alias_casefold alias in
        (* Same-process exemption: a holder row whose pid IS this
           registration's pid is the same process reclaiming its alias under
           a new session_id — the documented managed-relaunch flow (see
           [old_alias_opt] in the MCP register handler and the
           register-serializes-with-concurrent-enqueue regression test).
           Eviction remains correct there; only a DIFFERENT live process
           holding the alias is a hijack. When both rows carry a
           pid_start_time they must agree, so a recycled PID cannot claim
           the exemption. *)
        let same_process (conflict : registration) =
          match conflict.pid, pid with
          | Some cpid, Some npid when cpid = npid -> (
              match conflict.pid_start_time, pid_start_time with
              | Some cst, Some nst -> cst = nst
              | _ -> true)
          | _ -> false
        in
        (match
           List.find_opt
             (fun reg ->
               alias_casefold reg.alias = target
               && reg.session_id <> session_id
               && Option.is_some reg.pid
               && registration_is_alive reg
               && not (same_process reg))
             regs
         with
         | Some conflict ->
             let suggestion =
               match suggest_alias_prime regs ~base_alias:alias with
               | Some s -> Printf.sprintf " Suggested free alias: '%s'." s
               | None -> ""
             in
             invalid_arg
               (Printf.sprintf
                  "register rejected: alias '%s' is currently held by an alive \
                   session '%s'.%s"
                  alias conflict.session_id suggestion)
         | None -> ());
        let already_owns_alias =
          List.exists
            (fun reg ->
              reg.session_id = session_id
              && alias_casefold reg.alias = target)
            regs
        in
        if
          not already_owns_alias
          && pending_permission_exists_for_alias_unlocked t alias
        then
          invalid_arg
            (Printf.sprintf
               "register rejected: alias '%s' has pending permission state \
                from a prior owner — wait for it to resolve or time out"
               alias);
        (* Split registrations into:
           - conflicting: entries with our NEW alias held by a DIFFERENT session
             (alias conflict — must evict to claim the alias)
           - rest: everything else (our own prior entry if any, other sessions)
           We do NOT use a single partition with `||` because that wrongly
           evicts our own prior entry when renaming within the same session,
           which causes duplicate registry entries for the same session_id.
           See: same-session re-registration must update in-place, not evict+add.
           Case-insensitive: "Lyra-Quill" evicts "lyra-quill" (same identity). *)
        let conflicting, rest =
          List.partition
            (fun reg -> alias_casefold reg.alias = alias_casefold alias && reg.session_id <> session_id)
            regs
        in
        (* #378: additionally filter rest to remove case-folded alias matches
           with different session — prevents duplicate aliases in kept list. *)
        let rest =
          List.filter
            (fun reg -> not (alias_casefold reg.alias = alias_casefold alias && reg.session_id <> session_id))
            rest
        in
        (* Same-session re-registration (alias changed or pid/registered_at
           refresh): update in-place by replacing the old entry in [rest]. *)
        (* Look up old entry to preserve DND state + confirmed_at + client_type + plugin_version + compacting + role
           across re-registration. *)
        let old_reg_opt = List.find_opt (fun reg -> reg.session_id = session_id) rest in
        let old_state =
          match old_reg_opt with
          | Some r -> (r.dnd, r.dnd_since, r.dnd_until, r.confirmed_at, r.client_type, r.plugin_version, r.compacting, r.enc_pubkey, r.ed25519_pubkey, r.pubkey_signed_at, r.pubkey_sig, r.last_activity_ts, r.role, r.compaction_count, r.automated_delivery, r.tmux_location, r.cwd, r.metadata_opt_out, r.opaque_host_id)
          | None -> (false, None, None, None, client_type, None, None, enc_pubkey, None, None, None, None, role, 0, None, tmux_location, cwd, metadata_opt_out, opaque_host_id)
        in
        (* #529: log when a fresh registration has session_id ≠ alias.
           The inbox filename is based on session_id (original value), so when they
           differ, operators may see unexpected filenames (e.g. "session-a.inbox.json"
           instead of "storm-ember.inbox.json"). The broker itself handles this
           correctly — the sender resolves alias→session_id via the registry, so
           both enqueue and drain use the same session_id-based path. This log
           event provides visibility into when this configuration occurs. *)
        (if session_id <> alias then
          try
            let ts = Unix.gettimeofday () in
            let fields =
              [ ("ts", `Float ts)
              ; ("event", `String "session_id_differs_from_alias")
              ; ("session_id", `String session_id)
              ; ("alias", `String alias)
              ]
            in
            log_broker_event ~broker_root:(root t) "session_id_differs_from_alias" fields
          with _ -> ());
          let new_reg =
          let (dnd, dnd_since, dnd_until, old_confirmed_at, old_client_type, old_plugin_version, old_compacting, old_enc_pubkey, old_ed25519_pubkey, old_pubkey_signed_at, old_pubkey_sig, old_last_activity_ts, old_role, old_compaction_count, old_automated_delivery, old_tmux_location, _old_cwd, _old_metadata_opt_out, old_opaque_host_id) = old_state in
          let effective_client_type = match client_type with
            | Some _ -> client_type
            | None -> old_client_type
          in
          let effective_plugin_version = match plugin_version with
            | Some _ -> plugin_version
            | None -> old_plugin_version
          in
          let effective_enc_pubkey = match enc_pubkey with
            | Some _ -> enc_pubkey
            | None -> old_enc_pubkey
          in
          let effective_ed25519_pubkey = match ed25519_pubkey with
            | Some _ -> ed25519_pubkey
            | None -> old_ed25519_pubkey
          in
          let effective_pubkey_signed_at = match pubkey_signed_at with
            | Some _ -> pubkey_signed_at
            | None -> old_pubkey_signed_at
          in
          let effective_pubkey_sig = match pubkey_sig with
            | Some _ -> pubkey_sig
            | None -> old_pubkey_sig
          in
          let effective_role = match role with
            | Some _ -> role
            | None -> old_role
          in
          let effective_tmux_location = match tmux_location with
            | Some _ -> tmux_location
            | None -> old_tmux_location
          in
          (* herdr wake targets: same preserve-on-None semantics as
             tmux_location, sourced from old_reg_opt (the pre-existing
             old_state tuple is wide enough already). *)
          let effective_herdr_pane = match herdr_pane with
            | Some _ -> herdr_pane
            | None -> Option.bind old_reg_opt (fun r -> r.herdr_pane)
          in
          let effective_herdr_socket = match herdr_socket with
            | Some _ -> herdr_socket
            | None -> Option.bind old_reg_opt (fun r -> r.herdr_socket)
          in
          { session_id; alias; pid; pid_start_time
          ; registered_at = Some (Unix.gettimeofday ())
          ; canonical_alias = Some (compute_canonical_alias ~deprecate_canonical_alias:t.deprecate_canonical_alias ~alias ~broker_root:(root t) ())
          ; dnd; dnd_since; dnd_until
          ; client_type = effective_client_type
          ; plugin_version = effective_plugin_version
          ; confirmed_at = old_confirmed_at
          ; enc_pubkey = effective_enc_pubkey
          ; ed25519_pubkey = effective_ed25519_pubkey
          ; pubkey_signed_at = effective_pubkey_signed_at
          ; pubkey_sig = effective_pubkey_sig
          ; compacting = old_compacting
          ; last_activity_ts = old_last_activity_ts
          ; role = effective_role
          ; compaction_count = old_compaction_count
          ; automated_delivery = old_automated_delivery
          ; tmux_location = effective_tmux_location
          ; herdr_pane = effective_herdr_pane
          ; herdr_socket = effective_herdr_socket
          ; cwd
          ; metadata_opt_out
          ; registered_by
          ; opaque_host_id = old_opaque_host_id }
        in
        let kept =
          match
            List.partition (fun reg -> reg.session_id = session_id) rest
          with
          | [], others ->
              (* no prior entry for this session — fresh registration: add new one *)
              new_reg :: others
          | [ _old_reg ], others ->
              (* prior entry found — update alias/pid/start_time in place *)
              new_reg :: others
          | _multiple, others ->
              (* edge case: same session had multiple entries (shouldn't happen
                 with the fixed logic, but guard defensively) — keep first, drop rest *)
              new_reg :: others
        in
        (* #dual-alias-fix: final defensive dedup — ensure no other entries
           with the same session_id survived the partition logic. This guards
           against races where two processes register different aliases for
           the same session_id concurrently. *)
        let kept =
          let dominated, clean =
            List.partition
              (fun reg -> reg.session_id = session_id && reg.alias <> new_reg.alias)
              kept
          in
          (if dominated <> [] then begin
            let dominated_aliases =
              String.concat ", " (List.map (fun r -> r.alias) dominated)
            in
            (try
              log_broker_event ~broker_root:(root t) "dual_alias_dedup"
                [ ("ts", `Float (Unix.gettimeofday ()))
                ; ("session_id", `String session_id)
                ; ("kept_alias", `String alias)
                ; ("dropped_aliases", `String dominated_aliases)
                ]
            with _ -> ())
          end);
          clean
        in
        save_registrations t kept;
        (* Migrate undrained inbox messages from any evicted conflicting reg.
           Done WHILE holding the registry lock so a concurrent enqueue cannot
           resolve the alias to the stale session_id and write to the
           about-to-be-deleted inbox file. Inbox locks are taken sequentially
           under the registry lock — never nested — and always
           old-then-new, so two concurrent re-registers serialize cleanly
           through the registry mutex. *)
        List.iter
          (fun reg ->
            (* conflicting only contains entries with alias=alias &&
               session_id<>session_id, so this condition is always true;
               kept for clarity and safety *)
            if reg.session_id <> session_id then begin
              let migrated =
                with_inbox_lock t ~session_id:reg.session_id (fun () ->
                    let msgs = load_inbox t ~session_id:reg.session_id in
                    if msgs <> [] then
                      save_inbox t ~session_id:reg.session_id [];
                    (try Unix.unlink
                           (inbox_path t ~session_id:reg.session_id)
                     with Unix.Unix_error _ -> ());
                    (* #627: delete the lease file for the evicted registration.
                       Without this, the old session's lease retains recent mtime,
                       causing registration_is_alive to return true → stale session
                       not dead-lettered. Lease deletion mirrors inbox deletion above. *)
                    (try Unix.unlink
                           (lease_file_path t ~session_id:reg.session_id)
                     with Unix.Unix_error _ -> ());
                    msgs)
              in
              if migrated <> [] then
                with_inbox_lock t ~session_id (fun () ->
                    let current = load_inbox t ~session_id in
                    save_inbox t ~session_id (current @ migrated))
            end)
          conflicting));
    (* Docker: touch the lease file so cross-container peers see this session
       as alive via the shared broker volume. Inlined here (instead of calling
       touch_session) because touch_session is defined later in this module and
       OCaml requires forward declarations for cross-references. *)
    if in_docker_mode () then
      (try
         (match docker_broker_root () with
          | Error e ->
              Printf.eprintf "[touch_session] docker_broker_root error: %s\n%!" e
          | Ok root ->
              let dir = Filename.concat root docker_lease_dir_name in
              mkdir_p ~mode:0o755 dir;
              let path = Filename.concat dir session_id in
              (* Use open+O_CREAT to create, then utimes to set mtime *)
              let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_NOCTTY; Unix.O_NONBLOCK; Unix.O_WRONLY] 0o644 in
              Unix.close fd;
              Unix.utimes path 0.0 (Unix.gettimeofday ()))
        with Unix.Unix_error _ -> ())

  (** Update only the wake-target metadata of an existing registration.
      [Some v] overwrites the stored value; [None] leaves it unchanged
      (targets are never cleared here — a hook fire from outside tmux/herdr
      must not erase a previously captured pane). No-op when [session_id]
      has no registration. Total: never raises. *)
  let update_wake_targets t ~session_id ?(tmux_location = None)
      ?(herdr_pane = None) ?(herdr_socket = None) () =
    try
      if tmux_location = None && herdr_pane = None && herdr_socket = None then ()
      else
        with_registry_lock t (fun () ->
            let regs = load_registrations t in
            let changed = ref false in
            let apply nu old = match nu with None -> old | Some _ -> nu in
            let regs' =
              List.map
                (fun r ->
                  if r.session_id <> session_id then r
                  else begin
                    let r' =
                      { r with
                        tmux_location = apply tmux_location r.tmux_location
                      ; herdr_pane = apply herdr_pane r.herdr_pane
                      ; herdr_socket = apply herdr_socket r.herdr_socket
                      }
                    in
                    if r' <> r then changed := true;
                    r'
                  end)
                regs
            in
            if !changed then save_registrations t regs')
    with _ -> ()

  (** Replace all wake-target metadata of an existing registration exactly.
      Unlike [update_wake_targets], [None] clears a field. Session-boundary
      hooks use this operation so a session that moved outside tmux/herdr
      cannot retain a stale pane from an earlier process or environment. *)
  let replace_wake_targets t ~session_id ~tmux_location ~herdr_pane
      ~herdr_socket () =
    try
      with_registry_lock t (fun () ->
          let regs = load_registrations t in
          let changed = ref false in
          let regs' =
            List.map
              (fun r ->
                if r.session_id <> session_id then r
                else
                  let r' = { r with tmux_location; herdr_pane; herdr_socket } in
                  if r' <> r then changed := true;
                  r')
              regs
          in
          if !changed then save_registrations t regs')
    with _ -> ()

  (** True if [alias] contains '@' — indicating a remote alias that cannot be
      resolved via the local registry and must be sent via the relay outbox. *)
  let is_remote_alias alias =
    String.exists (fun c -> c = '@') alias

  (** Generate a v4 UUID for locally-assigned message IDs.
      This is called at enqueue time so every locally-sent message gets a
      stable, globally-unique ID that can be used to anchor sticker reactions. *)
  let generate_msg_id () =
    Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())

  (* B127: result of a local/relay enqueue. [Local_live] = written to an
     alive peer's durable inbox; [Local_offline] = written to a known but
     not-alive peer's durable inbox (will drain on next start/resume);
     [Relay_outbox] = remote alias@host staged for the relay connector. *)
  type enqueue_result =
    | Local_live of { session_id : string }
    | Local_offline of { session_id : string }
    | Relay_outbox

  (* B127: how long a dead registration with a non-empty offline inbox is
     protected from destructive sweep. After the TTL, sweep drops the reg and
     dead-letters the inbox (recoverable via register redelivery). Override
     with C2C_OFFLINE_MAIL_TTL_S (seconds). Default 7 days. *)
  let offline_mail_ttl_s () =
    match Sys.getenv_opt "C2C_OFFLINE_MAIL_TTL_S" with
    | Some v -> (try float_of_string v with _ -> 7. *. 24. *. 3600.)
    | None -> 7. *. 24. *. 3600.

  (* Prefer the most recently registered match so offline mail lands on the
     newest incarnation of an alias (same preference re-register uses when
     migrating inboxes from conflicting rows). *)
  let pick_offline_session_id (matches : registration list) : string option =
    let scored =
      List.map
        (fun (reg : registration) ->
          let score =
            match reg.registered_at with Some t -> t | None -> 0.
          in
          (score, reg.session_id))
        matches
    in
    match List.sort (fun (a, _) (b, _) -> compare b a) scored with
    | (_, sid) :: _ -> Some sid
    | [] -> None

  let matching_regs_for_alias t alias =
    let target = alias_casefold alias in
    load_registrations t
    |> List.filter (fun (reg : registration) ->
           alias_casefold reg.alias = target
           && not (is_expired_codex_hook_auto_registration reg))

  (* Shared local-inbox write used by live + offline enqueue paths. *)
  let write_local_dm_to_session t ~from_alias ~to_alias ~content ~deferrable
      ~ephemeral ~session_id ~offline =
    (* Docker lease touch only for live peers — offline pids don't need a
       lease keep-alive and may not exist. *)
    if not offline then
      (try
         if in_docker_mode () then begin
           (match docker_broker_root () with
            | Error e ->
                Printf.eprintf "[enqueue_message] docker_broker_root error: %s\n%!" e
            | Ok root ->
                let dir = Filename.concat root docker_lease_dir_name in
                mkdir_p ~mode:0o755 dir;
                let path = Filename.concat dir session_id in
                let fd =
                  Unix.openfile path
                    [ Unix.O_CREAT; Unix.O_NOCTTY; Unix.O_NONBLOCK; Unix.O_WRONLY ]
                    0o644
                in
                Unix.close fd;
                Unix.utimes path 0.0 (Unix.gettimeofday ()))
         end
       with Unix.Unix_error _ -> ());
    if debug_enabled then
      Printf.eprintf
        "[DEBUG enqueue] from=%s to=%s session_id=%s offline=%b\n%!" from_alias
        to_alias session_id offline;
    flush stderr;
    with_inbox_lock t ~session_id (fun () ->
        let current = load_inbox t ~session_id in
        (* B127 AC6: generate the id once so the persisted row and the
           dm_enqueue broker.log event carry the same message_id. *)
        let mid = generate_msg_id () in
        let next =
          current
          @ [ { from_alias
              ; to_alias
              ; content
              ; deferrable
              ; reply_via = None
              ; enc_status = None
              ; ts = Unix.gettimeofday ()
              ; ephemeral
              ; message_id = Some mid
              ; pow_difficulty = None
              }
            ]
        in
        let ipath = inbox_path t ~session_id in
        if debug_enabled then
          Printf.eprintf
            "[DEBUG enqueue] inbox_path=%s current_len=%d next_len=%d\n%!" ipath
            (List.length current) (List.length next);
        flush stderr;
        (try
           let broker_root = root t in
           let ts = Unix.gettimeofday () in
           let fields =
             [ ("ts", `Float ts)
             ; ("msg_type", `String "enqueue_message")
             ; ("from_alias", `String from_alias)
             ; ("to_alias", `String to_alias)
             ; ("resolved_session_id", `String session_id)
             ; ("inbox_path", `String ipath)
             ; ("offline", `Bool offline)
             ; ("message_id", `String mid)
             ]
           in
           log_broker_event ~broker_root "dm_enqueue" fields
         with _ -> ());
        save_inbox t ~session_id next);
    (* Pending-verdict DM interception: if the message body contains
       [c2c:pending-verdict:<perm_id>:<approve|deny>] and the sender is
       in the entry's supervisors list, resolve the pending entry. The DM
       is already delivered above — this is a pure side-effect. *)
    (try
       match parse_pending_verdict content with
       | Some (perm_id, v) ->
           (match find_pending_permission t perm_id with
            | Some pending
              when List.mem (alias_casefold from_alias)
                     (List.map alias_casefold pending.supervisors) ->
                let _changed =
                  mark_pending_resolved t ~perm_id
                    ~ts:(Unix.gettimeofday ()) ~verdict:(Some v) ()
                in
                if debug_enabled then
                  Printf.eprintf
                    "[pending-verdict] resolved perm_id=%s verdict=%s by %s\n%!"
                    perm_id
                    (match v with `Approve -> "approve" | `Deny -> "deny")
                    from_alias
            | _ ->
                if debug_enabled then
                  Printf.eprintf
                    "[pending-verdict] perm_id not found or sender not supervisor\n%!")
       | None -> ()
     with _ -> ());
    if offline then Local_offline { session_id }
    else Local_live { session_id }

  let enqueue_message_with_result t ~from_alias ~to_alias ~content
      ?(deferrable = false) ?(ephemeral = false) () =
    if debug_enabled then
      Printf.eprintf "[DEBUG enqueue ENTER] from=%s to=%s\n%!" from_alias to_alias;
    (* Hardening B: check shell-launch-location mismatch and warn if sender's
       cwd has drifted from the expected path at launch time. Called here for
       all sends (reserved-alias check is separate below). *)
    check_worktree_mismatch t ~from_alias;
    (* Reject messages claiming a reserved system from_alias — prevents spoofing. *)
    if is_reserved_system_alias from_alias then
      invalid_arg
        (Printf.sprintf
           "send rejected: from_alias '%s' is a reserved system alias" from_alias)
    else if is_remote_alias to_alias then begin
      (* Remote alias: append to relay outbox for async forwarding by sync loop.
         Note: ephemeral semantics over the relay are not yet wired in v1 —
         the relay outbox path persists by design. Cross-host ephemeral is a
         follow-up. For now, [ephemeral] only takes effect on local delivery. *)
      C2c_relay_connector.append_outbox_entry t.root ~from_alias ~to_alias
        ~content ();
      Relay_outbox
    end else
      with_registry_lock t (fun () ->
          match resolve_live_session_id_by_alias t to_alias with
          | Unknown_alias ->
              (* #silent-send Bug 3: if the alias is not a remote alias (no @),
                 it should exist locally. Unknown_alias here means it's genuinely
                 unknown — not registered on this broker and not a remote target.
                 Reject with a clear error rather than silently dropping to relay. *)
              if not (is_remote_alias to_alias) then
                invalid_arg
                  ("enqueue_message rejected: alias '" ^ to_alias
                   ^ "' is not registered; message not queued")
              else begin
                C2c_relay_connector.append_outbox_entry t.root ~from_alias
                  ~to_alias ~content ();
                Relay_outbox
              end
          | All_recipients_dead ->
              (* B127: known alias, no live process — queue into the durable
                 inbox of the most recent matching registration. Unknown
                 aliases still raise above. Does NOT fake liveness. *)
              (match
                 pick_offline_session_id (matching_regs_for_alias t to_alias)
               with
               | None ->
                   (* Defensive: resolve said matches existed; if none remain,
                      treat as unknown rather than silent drop. *)
                   invalid_arg
                     ("enqueue_message rejected: alias '" ^ to_alias
                      ^ "' is not registered; message not queued")
               | Some session_id ->
                   write_local_dm_to_session t ~from_alias ~to_alias ~content
                     ~deferrable ~ephemeral ~session_id ~offline:true)
          | Resolved session_id ->
              write_local_dm_to_session t ~from_alias ~to_alias ~content
                ~deferrable ~ephemeral ~session_id ~offline:false)

  let enqueue_message t ~from_alias ~to_alias ~content ?(deferrable = false)
      ?(ephemeral = false) () =
    ignore
      (enqueue_message_with_result t ~from_alias ~to_alias ~content ~deferrable
         ~ephemeral ())

  type send_all_result =
    { sent_to : string list
    ; skipped : (string * string) list
    }

  (** @deprecated Use [C2c_send_handlers.broadcast_to_all] instead.

      This plaintext fan-out does NOT encrypt per-recipient even when
      recipients have published [enc_pubkey] values.  #671 S1 replaced
      the MCP path with a per-recipient [encrypt_content_for_recipient]
      loop; the CLI path ([c2c send-all] in [c2c.ml]) still calls this
      function directly — that's the remaining plaintext gap.

      Follow-up: extract a non-Lwt helper from [broadcast_to_all] that
      both the MCP handler and the CLI can share, then remove this
      function.  See [.collab/findings/2026-05-03T15-55-00Z-stanza-coder-cli-send-all-plaintext-gap.md].

      Original doc: 1:N broadcast primitive. Fan out [content] to every
      unique alias in the registry except the sender and any alias in
      [exclude_aliases]. A recipient whose registrations are all dead is
      skipped with reason "not_alive" rather than raising — partial
      failure is the normal case for broadcast. Per-recipient enqueue
      reuses [with_inbox_lock] so this interlocks with concurrent 1:1
      sends on the same inbox. *)
  let send_all t ~from_alias ~content ~exclude_aliases =
    if debug_enabled then Printf.eprintf "[DEBUG send_all] from=%s content=%s exclude=%s\n%!" from_alias content
      (String.concat "," exclude_aliases);
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
        let sent = ref [] in
        let skipped = ref [] in
        List.iter
          (fun reg ->
            if Hashtbl.mem seen reg.alias then ()
            else begin
              Hashtbl.add seen reg.alias ();
              if reg.alias = from_alias then ()
              else if List.mem reg.alias exclude_aliases then ()
              else
                match resolve_live_session_id_by_alias t reg.alias with
                | Resolved session_id ->
                    with_inbox_lock t ~session_id (fun () ->
                        let current = load_inbox t ~session_id in
                        (* Same id in the persisted row and the log event. *)
                        let mid = generate_msg_id () in
                        let next =
                          current
                          @ [ { from_alias; to_alias = reg.alias; content; deferrable = false; reply_via = None; enc_status = None; ts = Unix.gettimeofday (); ephemeral = false; message_id = Some mid; pow_difficulty = None } ]
                        in
                        let ipath = inbox_path t ~session_id in
                        (* Per-DM trace for send_all fan-out — same diagnostic
                           value as enqueue_message tracing. *)
                        (try
                          let ts = Unix.gettimeofday () in
                          let fields =
                            [ ("ts", `Float ts)
                            ; ("msg_type", `String "send_all")
                            ; ("from_alias", `String from_alias)
                            ; ("to_alias", `String reg.alias)
                            ; ("resolved_session_id", `String session_id)
                            ; ("inbox_path", `String ipath)
                            ; ("message_id", `String mid)
                            ]
                          in
                          let broker_root = root t in
                          log_broker_event ~broker_root "dm_enqueue" fields
                        with _ -> ());
                        save_inbox t ~session_id next);
                    sent := reg.alias :: !sent
                | All_recipients_dead ->
                    skipped := (reg.alias, "not_alive") :: !skipped
                | Unknown_alias -> ()
            end)
          regs;
        { sent_to = List.rev !sent; skipped = List.rev !skipped })

  let read_inbox t ~session_id = load_inbox t ~session_id

  (* ---------- inbox archive (drain is append-only, not destructive) ----------
     Non-ephemeral messages drained via poll_inbox are appended to
     <root>/archive/<session_id>.jsonl BEFORE the live inbox is cleared.
     This means drained non-ephemeral messages become part of a per-session,
     append-only history that tools like `history` can read back.

     Messages sent with [ephemeral=true] are filtered out of the archive
     append in [drain_inbox] / [drain_inbox_push] (#284). They are still
     returned to the caller and removed from the live inbox; they simply
     leave no persistent server-side record post-delivery.

     If the archive append fails (disk full, permission, etc.) we do NOT
     clear the inbox, so the "drained non-ephemeral messages are never
     deleted" invariant holds atomically under the per-inbox lock. *)

  let archive_dir t = Filename.concat t.root "archive"

  let archive_path t ~session_id =
    Filename.concat (archive_dir t) (session_id ^ ".jsonl")

  let archive_lock_path t ~session_id =
    Filename.concat (archive_dir t) (session_id ^ ".lock")

  let ensure_archive_dir t =
    ensure_root t;
    let d = archive_dir t in
    if not (Sys.file_exists d) then Unix.mkdir d 0o700

  (* POSIX fcntl lock on a per-session sidecar file. Scoped per session so
     a drain by one session never blocks drains by another. Same pattern
     as the inbox lock. *)
  let with_archive_lock t ~session_id f =
    ensure_archive_dir t;
    let fd =
      Unix.openfile (archive_lock_path t ~session_id)
        [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  (* [drained_by]: free-form label for the path that drained these messages.
     Persisted as a top-level archive field so investigators can tell which
     code path archived a given record (#387 slice B). Convention:
       "hook"        — Claude Code PostToolUse inbox hook (c2c_inbox_hook,
                       and the equivalent c2c.ml [hook] subcommand).
       "watcher"     — channel-notification watcher in the MCP server.
       "poll_inbox"  — explicit MCP poll_inbox tool call.
       "cli_poll"    — `c2c poll-inbox` / `c2c peek-inbox` CLI.
       "pty"         — codex PTY deliver loop.
       "tmux"        — tmux paste-and-submit deliver path.
       "oc_plugin"   — OpenCode plugin spool path.
       "unknown"     — default when caller didn't specify (legacy / tests).
     Older archive entries omit the field; readers default to "unknown". *)
  let append_archive ?(drained_by = "unknown") t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_archive_lock t ~session_id (fun () ->
            (* Mode 0o600: archive records carry DM content, must not be
               world-readable. *)
            (* Not broker.log: DM archive append, not append_jsonl target. *)
            let oc =
              open_out_gen
                [ Open_wronly; Open_append; Open_creat ]
                0o600 (archive_path t ~session_id)
            in
                Fun.protect
                  ~finally:(fun () -> try close_out oc with _ -> ())
                  (fun () ->
                    let ts = Unix.gettimeofday () in
                    List.iter
                      (fun ({ from_alias; to_alias; content; deferrable; message_id } : message) ->
                        let base =
                          [ ("drained_at", `Float ts)
                          ; ("drained_by", `String drained_by)
                          ; ("session_id", `String session_id)
                          ; ("from_alias", `String from_alias)
                          ; ("to_alias", `String to_alias)
                          ; ("content", `String content)
                          ]
                        in
                        let with_deferrable = if deferrable then base @ [("deferrable", `Bool true)] else base in
                        let record = match message_id with
                          | Some mid -> `Assoc (with_deferrable @ [("message_id", `String mid)])
                          | None -> `Assoc with_deferrable
                        in
                        output_string oc (Yojson.Safe.to_string record);
                        output_char oc '\n')
                      messages));

  type archive_entry =
    { ae_drained_at : float
    ; ae_from_alias : string
    ; ae_to_alias : string
    ; ae_content : string
    ; ae_deferrable : bool
    ; ae_drained_by : string
    ; ae_message_id : string option
        (* v2+: relay-assigned message ID for cross-referencing with sticker
           reactions. None for archives written before this field existed.
           When present, use the first 8 chars as a short prefix for CLI display
           (e.g. [abc12345] in poll-inbox output). *)
    }

  let archive_entry_of_json json =
    let open Yojson.Safe.Util in
    { ae_drained_at =
        (match json |> member "drained_at" with
         | `Float f -> f
         | `Int i -> float_of_int i
         | _ -> 0.0)
    ; ae_from_alias =
        (try json |> member "from_alias" |> to_string with _ -> "")
    ; ae_to_alias =
        (try json |> member "to_alias" |> to_string with _ -> "")
    ; ae_content =
        (try json |> member "content" |> to_string with _ -> "")
    ; ae_deferrable =
        (* Older archive records omit the field; default false matches
           the implicit default at write time. *)
        (try json |> member "deferrable" |> to_bool with _ -> false)
    ; ae_drained_by =
        (* Older archive records (pre-#387) omit the field; default to
           "unknown" so legacy entries continue to parse. *)
        (try json |> member "drained_by" |> to_string with _ -> "unknown")
    ; ae_message_id =
        (* v2 field: older archives omit it. Default None for forward/back
           compat with pre-message_id archives. *)
        (match json |> member "message_id" with
         | `String s when s <> "" -> Some s
         | _ -> None)
    }

  (* Return up to [limit] most-recent archive entries for [session_id],
     newest first. Reads the per-session jsonl file under the archive
     lock so concurrent appends can't interleave. Missing file => []. *)
  let read_archive t ~session_id ~limit =
    if limit <= 0 then []
    else
      with_archive_lock t ~session_id (fun () ->
          let path = archive_path t ~session_id in
          if not (Sys.file_exists path) then []
          else
            let ic = open_in path in
            Fun.protect
              ~finally:(fun () -> try close_in ic with _ -> ())
              (fun () ->
                let rec loop acc =
                  match input_line ic with
                  | exception End_of_file -> List.rev acc
                  | line ->
                      let line = String.trim line in
                      if line = "" then loop acc
                      else
                        let entry =
                          try
                            Some (archive_entry_of_json
                                    (Yojson.Safe.from_string line))
                          with _ -> None
                        in
                        (match entry with
                         | Some e -> loop (e :: acc)
                         | None -> loop acc)
                in
                let all = loop [] in
                (* [all] is now oldest-first. Take the last [limit] and
                   reverse to get newest-first. *)
                let total = List.length all in
                let drop = max 0 (total - limit) in
                let rec drop_n n = function
                  | [] -> []
                  | _ :: rest when n > 0 -> drop_n (n - 1) rest
                  | xs -> xs
                in
                List.rev (drop_n drop all)))

  (* [find_message_by_id t ~alias ~id_prefix] searches the archive for the
     session registered under [alias] for an entry whose [ae_message_id]
     starts with [id_prefix]. Returns [Ok entry] on unique match, [Error msg]
     on ambiguity or missing. Used by sticker-react to anchor reactions to
     the original message being reacted to. *)
  let find_message_by_id t ~alias ~id_prefix =
    let regs = load_registrations t in
    let matches = List.filter (fun (r : registration) -> r.alias = alias) regs in
    match matches with
    | [] -> Error ("alias not found: " ^ alias)
    | [ r ] ->
        let entries = read_archive t ~session_id:r.session_id ~limit:500 in
        let matching =
          List.filter (fun e ->
            match e.ae_message_id with
            | Some mid -> String.length mid >= String.length id_prefix &&
                          String.sub mid 0 (String.length id_prefix) = id_prefix
            | None -> false
          ) entries
        in
        (match matching with
         | [] -> Error ("no message found with id prefix: " ^ id_prefix)
         | [ e ] -> Ok e
         | _ ->
             let prefixes = List.map (fun e -> Option.value e.ae_message_id ~default:"") matching in
             Error ("ambiguous id prefix '" ^ id_prefix ^ "' matches multiple: " ^
                    String.concat ", " (List.map (fun s -> String.sub s 0 (min 8 (String.length s))) prefixes)))
    | _ -> Error ("alias '" ^ alias ^ "' matches multiple sessions — use session_id directly")

  (* #307a: histogram-compute over recent archive entries for a session.
     Counts inbound messages by deferrable flag and groups by sender.
     Filters: drop entries older than [min_ts] when set; cap to most
     recent [limit] when set. Both filters compose; if both unset, all
     archived entries are counted.

     The histogram measures sender INTENT (the deferrable flag at write
     time), not delivery actuals. See #303 / #307a design. *)
  type delivery_mode_sender_count =
    { dms_alias : string
    ; dms_total : int
    ; dms_push : int
    ; dms_poll : int
    }

  type delivery_mode_histogram_result =
    { dmh_total : int
    ; dmh_push : int
    ; dmh_poll : int
    ; dmh_by_sender : delivery_mode_sender_count list
    }

  let delivery_mode_histogram t ~session_id ?min_ts ?last_n () =
    let limit = match last_n with
      | Some n when n > 0 -> n
      | Some _ -> 0
      | None -> max_int / 2
    in
    let entries = read_archive t ~session_id ~limit in
    let entries = match min_ts with
      | Some ts -> List.filter (fun e -> e.ae_drained_at >= ts) entries
      | None -> entries
    in
    let total = List.length entries in
    let push = List.length (List.filter (fun e -> not e.ae_deferrable) entries) in
    let poll = total - push in
    (* Group by from_alias. Hashtbl preserves first-seen order via the
       ordered list of keys we accumulate. *)
    let counts : (string, int * int) Hashtbl.t = Hashtbl.create 16 in
    let order = ref [] in
    List.iter
      (fun e ->
        let a = e.ae_from_alias in
        let (p, l) =
          match Hashtbl.find_opt counts a with
          | Some pair -> pair
          | None -> order := a :: !order; (0, 0)
        in
        let pair' =
          if e.ae_deferrable then (p, l + 1) else (p + 1, l)
        in
        Hashtbl.replace counts a pair')
      entries;
    let by_sender =
      List.rev_map
        (fun a ->
          let (p, l) = Hashtbl.find counts a in
          { dms_alias = a; dms_total = p + l; dms_push = p; dms_poll = l })
        !order
    in
    (* Sort by total desc; ties broken by alias asc for stable output. *)
    let by_sender =
      List.sort
        (fun a b ->
          let c = compare b.dms_total a.dms_total in
          if c <> 0 then c else compare a.dms_alias b.dms_alias)
        by_sender
    in
    { dmh_total = total; dmh_push = push; dmh_poll = poll; dmh_by_sender = by_sender }

  (* #392 slice 5: tag histogram. Mirror of delivery_mode_histogram but
     buckets archived inbound messages by recovered #392 tag (fail /
     blocking / urgent / none) instead of by deferrable flag. Like the
     delivery-mode counterpart this measures sender INTENT (the prefix
     present at archive-write time), not delivery actuals. *)
  type tag_sender_count =
    { ts_alias : string
    ; ts_total : int
    ; ts_fail : int
    ; ts_blocking : int
    ; ts_urgent : int
    ; ts_untagged : int
    }

  type tag_histogram_result =
    { th_total : int
    ; th_fail : int
    ; th_blocking : int
    ; th_urgent : int
    ; th_untagged : int
    ; th_by_sender : tag_sender_count list
    }

  let tag_histogram t ~session_id ?min_ts ?last_n () =
    let limit = match last_n with
      | Some n when n > 0 -> n
      | Some _ -> 0
      | None -> max_int / 2
    in
    let entries = read_archive t ~session_id ~limit in
    let entries = match min_ts with
      | Some ts -> List.filter (fun e -> e.ae_drained_at >= ts) entries
      | None -> entries
    in
    let bucket_of_content c =
      match extract_tag_from_content c with
      | Some "fail" -> `Fail
      | Some "blocking" -> `Blocking
      | Some "urgent" -> `Urgent
      | _ -> `None
    in
    let total = List.length entries in
    let count_bucket pred =
      List.length (List.filter (fun e -> pred (bucket_of_content e.ae_content)) entries)
    in
    let fail = count_bucket (function `Fail -> true | _ -> false) in
    let blocking = count_bucket (function `Blocking -> true | _ -> false) in
    let urgent = count_bucket (function `Urgent -> true | _ -> false) in
    let untagged = count_bucket (function `None -> true | _ -> false) in
    (* By-sender breakdown: tuple = (fail, blocking, urgent, untagged). *)
    let counts : (string, int * int * int * int) Hashtbl.t = Hashtbl.create 16 in
    let order = ref [] in
    List.iter
      (fun e ->
        let a = e.ae_from_alias in
        let (f, b, u, n) =
          match Hashtbl.find_opt counts a with
          | Some quad -> quad
          | None -> order := a :: !order; (0, 0, 0, 0)
        in
        let updated =
          match bucket_of_content e.ae_content with
          | `Fail -> (f + 1, b, u, n)
          | `Blocking -> (f, b + 1, u, n)
          | `Urgent -> (f, b, u + 1, n)
          | `None -> (f, b, u, n + 1)
        in
        Hashtbl.replace counts a updated)
      entries;
    let by_sender =
      List.rev_map
        (fun a ->
          let (f, b, u, n) = Hashtbl.find counts a in
          { ts_alias = a; ts_total = f + b + u + n; ts_fail = f
          ; ts_blocking = b; ts_urgent = u; ts_untagged = n })
        !order
    in
    let by_sender =
      List.sort
        (fun a b ->
          let c = compare b.ts_total a.ts_total in
          if c <> 0 then c else compare a.ts_alias b.ts_alias)
        by_sender
    in
    { th_total = total; th_fail = fail; th_blocking = blocking
    ; th_urgent = urgent; th_untagged = untagged; th_by_sender = by_sender }

  (* Skip the file write when the inbox is already empty. This keeps
     close_write events out of inotify streams — every tool call that
     auto-drains would otherwise fire a noisy event on an idle inbox,
     swamping agent-visibility monitors with meaningless drain churn.
     Semantic is unchanged: callers still get [] for an empty inbox.

     Drained messages are appended to the per-session archive file
     BEFORE the live inbox is cleared. If the archive append raises
     (disk full, permission, IO error), we let the exception propagate
     WITHOUT clearing the inbox — the drain fails atomically under the
     inbox lock, so the caller will see the error and the messages
     remain in the live inbox for retry. This upholds the "drained
     messages are never deleted, only archived" invariant even in the
     failure case. *)
  let drain_inbox ?(drained_by = "unknown") t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        (match messages with
         | [] -> ()
         | _ ->
             (* #284: ephemeral messages are returned to the caller for
                delivery but never appended to the archive. Their only
                persistent trace is the recipient's transcript / channel
                notification, which is per-session-local. *)
             let to_archive = List.filter (fun m -> not m.ephemeral) messages in
             (match to_archive with
              | [] -> ()
              | _ -> append_archive ~drained_by t ~session_id ~messages:to_archive);
             save_inbox t ~session_id []);
        messages)

  (* Like drain_inbox but only drains non-deferrable messages.  Deferrable
     messages stay in the inbox for the next explicit poll or idle-flush.
     Used by push paths (channel notification watcher, PostToolUse hook) to
     suppress low-priority messages that the sender marked as non-urgent. *)
  let drain_inbox_push ?(drained_by = "unknown") t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        let to_push = List.filter (fun m -> not m.deferrable) messages in
        let to_keep = List.filter (fun m -> m.deferrable) messages in
        (match to_push with
         | [] -> ()
         | _ ->
             (* #284: same archive-skip rule applies on the push path. *)
             let to_archive = List.filter (fun m -> not m.ephemeral) to_push in
             (match to_archive with
              | [] -> ()
              | _ -> append_archive ~drained_by t ~session_id ~messages:to_archive);
             save_inbox t ~session_id to_keep);
        to_push)

  (* Like drain_inbox but only drains messages satisfying [pred]; non-matching
     messages remain in the live inbox for later polls.  Used by the CLI's
     `poll-inbox --wait --from <alias>` / `wait-inbox --from <alias>` so
     waiting on one sender never consumes other senders' messages.  Same
     archive-before-clear invariant as drain_inbox: matching non-ephemeral
     messages are appended to the archive BEFORE the inbox is rewritten, all
     under the per-inbox lock. *)
  let drain_inbox_matching ?(drained_by = "unknown") t ~session_id ~pred =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        let matching, rest = List.partition pred messages in
        (match matching with
         | [] -> ()
         | _ ->
             (* #284: same archive-skip rule for ephemeral messages. *)
             let to_archive = List.filter (fun m -> not m.ephemeral) matching in
             (match to_archive with
              | [] -> ()
              | _ -> append_archive ~drained_by t ~session_id ~messages:to_archive);
             save_inbox t ~session_id rest);
        matching)

  type sweep_result =
    { dropped_regs : registration list
    ; deleted_inboxes : string list
    ; preserved_messages : int
    }

  let inbox_suffix = ".inbox.json"

  let dead_letter_path t = Filename.concat t.root "dead-letter.jsonl"

  let dead_letter_lock_path t =
    Filename.concat t.root "dead-letter.jsonl.lock"

  (* POSIX fcntl lock on a sidecar — serializes appends to dead-letter.jsonl
     across OCaml processes and against any Python path that also uses
     Unix.lockf/fcntl.lockf on the same sidecar. *)
  let with_dead_letter_lock t f =
    ensure_root t;
    let fd =
      Unix.openfile (dead_letter_lock_path t) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  (* #433: emit a structured `dead_letter_write` line in broker.log for
     every message dropped into dead-letter.jsonl. Without this, `c2c
     tail-log` is silent on dead-letter writes — contradicting the
     "log silent failures" rule. Best-effort: any IO error is swallowed
     (broker.log emission must never block the dead-letter write itself).
     The reason field defaults to "inbox_sweep" since that is the only
     current caller (sweep loop on a vanished session); future callers
     can pass a different reason to distinguish e.g. cross-host rejects. *)
  let log_dead_letter_write t ~reason ~session_id ~msg =
    (try
       let path = Filename.concat t.root "broker.log" in
       let line =
         `Assoc
           [ ("ts", `Float (Unix.gettimeofday ()))
           ; ("event", `String "dead_letter_write")
           ; ("reason", `String reason)
           ; ("from_session_id", `String session_id)
           ; ("from_alias", `String msg.from_alias)
           ; ("to_alias", `String msg.to_alias)
           ; ("msg_ts", `Float msg.ts)
           ]
         |> Yojson.Safe.to_string
       in
       C2c_io.append_jsonl path line
     with _ -> ())

  let append_dead_letter ?(reason = "inbox_sweep") t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_dead_letter_lock t (fun () ->
            (* Mode 0o600: dead-letter records carry the same envelope
               content as live inbox files (which Python writers create
               at 0o600), so this file must not be world-readable. *)
            (* Not broker.log: dead-letter append, not append_jsonl target. *)
            let oc =
              open_out_gen
                [ Open_wronly; Open_append; Open_creat ]
                0o600 (dead_letter_path t)
            in
            Fun.protect
              ~finally:(fun () -> try close_out oc with _ -> ())
              (fun () ->
                let ts = Unix.gettimeofday () in
                List.iter
                  (fun msg ->
                    let record =
                      `Assoc
                        [ ("deleted_at", `Float ts)
                        ; ("from_session_id", `String session_id)
                        ; ("message", message_to_json msg)
                        ]
                    in
                    output_string oc (Yojson.Safe.to_string record);
                    output_char oc '\n';
                    log_dead_letter_write t ~reason ~session_id ~msg)
                  messages))

  let inbox_file_session_id name =
    if Filename.check_suffix name inbox_suffix then
      Some (Filename.chop_suffix name inbox_suffix)
    else None

  let list_inbox_session_ids t =
    ensure_root t;
    let entries =
      try Sys.readdir t.root with Sys_error _ -> [||]
    in
    Array.fold_left
      (fun acc name ->
        match inbox_file_session_id name with
        | Some sid -> sid :: acc
        | None -> acc)
      []
      entries

  let try_unlink path =
    try Unix.unlink path; true
    with Unix.Unix_error _ -> false

  (* #383: classify why a confirmed registration was marked dead.
     - "timeout": provisional registration (never confirmed) expired
     - "killed": confirmed session with a PID that is no longer alive
     - "unknown": confirmed session with no PID (pidless row went dark) *)
  let peer_offline_reason (reg : registration) : string =
    match reg.confirmed_at with
    | None -> "timeout"
    | Some _ ->
        match reg.pid with
        | None -> "unknown"
        | Some _ -> "killed"

  (* Build the peer_offline message body for a given dead registration.
     Format matches the proposed envelope in #383. *)
  let peer_offline_message (reg : registration) : string =
    let detected_at = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
    let last_seen = match reg.last_activity_ts with
      | None -> "none"
      | Some ts -> Printf.sprintf "%.3f" ts
    in
    let reason = peer_offline_reason reg in
    (* Use bare alias for agent-friendliness: canonical aliases contain
       host/slug qualifiers that make pattern-matching harder for recipients.
       Bare alias is what agents naturally expect to match against. *)
    Printf.sprintf
      "<c2c event=\"peer_offline\" peer=\"%s\" detected_at=\"%s\" reason=\"%s\" last_seen=\"%s\"/>"
      reg.alias
      detected_at reason last_seen

  let sweep t =
    (* Partition under lock, but broadcast peer_offline AFTER releasing it
       to avoid nested lock issues with send_all (which also takes the
       registry lock and inbox locks). *)
    let dead_confirmed_regs : registration list ref = ref [] in
    let do_broadcast () =
      if !dead_confirmed_regs <> [] then
        List.iter
          (fun dead_reg ->
            let content = peer_offline_message dead_reg in
            (* Exclude the dead alias from receiving its own notification. *)
            ignore (send_all t ~from_alias:"broker" ~content ~exclude_aliases:[dead_reg.alias]))
          !dead_confirmed_regs
    in
    (* B127: keep a dead registration (and its inbox) when it still holds
       offline-queued mail within C2C_OFFLINE_MAIL_TTL_S. Anchor is the max of
       registered_at and newest inbox message ts. Past the TTL, reg drops and
       non-empty inboxes still go to dead-letter.jsonl (recoverable on
       re-register). Does NOT mark the peer alive. *)
    let offline_mail_protects t (reg : registration) =
      let msgs = load_inbox t ~session_id:reg.session_id in
      match msgs with
      | [] -> false
      | _ ->
          let newest =
            List.fold_left (fun acc (m : message) -> max acc m.ts) 0. msgs
          in
          let anchor =
            match reg.registered_at with Some ra -> max ra newest | None -> newest
          in
          Unix.gettimeofday () -. anchor < offline_mail_ttl_s ()
    in
    let result =
      with_registry_lock t (fun () ->
          let regs = load_registrations t in
          (* Dead: PID-based liveness check failed OR provisional registration
             that has never been confirmed and has timed out. *)
          let alive, dead = List.partition is_sweep_keepable regs in
          (* B127: offline-mail hold — keep dead regs with non-empty durable
             mail still inside the offline TTL so resume can drain exactly once. *)
          let protected, dead =
            List.partition (fun reg -> offline_mail_protects t reg) dead
          in
          let alive = alive @ protected in
          (* #383: capture confirmed dead aliases for peer_offline broadcast.
             Only confirmed registrations (confirmed_at = Some) were fully alive;
             provisional-only timeouts don't emit peer_offline.
             Offline-mail-protected regs are NOT broadcast as peer_offline here
             (they remain registered as known-offline mailboxes). *)
          dead_confirmed_regs :=
            List.fold_left
              (fun acc reg ->
                match reg.confirmed_at with
                | None -> acc  (* provisional — skip *)
                | Some _ -> reg :: acc)
              []
              dead;
          if dead <> [] then save_registrations t alive;
          let alive_sids =
            List.fold_left
              (fun acc reg -> reg.session_id :: acc)
              []
              alive
          in
          let all_inbox_sids = list_inbox_session_ids t in
          let preserved = ref 0 in
          let deleted =
            List.filter
              (fun sid ->
                if List.mem sid alive_sids then false
                else
                  (* Hold the inbox lock across read+preserve+delete so a
                     concurrent enqueue can't race the unlink. Any non-empty
                     content is appended to dead-letter.jsonl before the
                     inbox file is removed, so cleanup is non-destructive to
                     operator signal. We intentionally leave the .inbox.lock
                     sidecar in place: unlinking the lock file while another
                     process holds a lockf on a separate fd for the same
                     path would open a window for a new opener to get a
                     LOCK immediately against a different inode. Sidecar
                     files are empty, so keeping them is cheap. *)
                  with_inbox_lock t ~session_id:sid (fun () ->
                      let msgs = load_inbox t ~session_id:sid in
                      if msgs <> [] then begin
                        append_dead_letter t ~session_id:sid ~messages:msgs;
                        preserved := !preserved + List.length msgs
                      end;
                      try_unlink (inbox_path t ~session_id:sid)))
            all_inbox_sids
          in
          { dropped_regs = dead
          ; deleted_inboxes = deleted
          ; preserved_messages = !preserved
          })
    in
    do_broadcast ();
    result

  (** [registry_prune t ~managed_session_ids ~patterns] — remove dead test registrations.
      Partitions registrations into kept and pruned: a registration is pruned
      when BOTH (1) it is dead per [is_sweep_keepable] AND (2) its alias
      matches one of the [patterns] prefixes. Managed sessions (c2c start,
      identified by [managed_session_ids]) are always excluded regardless of
      alias or liveness. Returns the list of pruned registrations.
      Saves the updated registry (removing pruned entries).
      Does NOT touch inboxes — use [sweep] for that. *)
  let registry_prune t ~managed_session_ids ~patterns =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let is_test_pattern alias =
        List.exists (fun prefix ->
          String.length alias >= String.length prefix
          && String.sub alias 0 (String.length prefix) = prefix)
          patterns
      in
      let to_keep, to_prune =
        List.partition (fun reg ->
          (* Always keep managed sessions *)
          if List.mem reg.session_id managed_session_ids then true
          (* Keep if alive or if alias doesn't match any test pattern *)
          else is_sweep_keepable reg || not (is_test_pattern reg.alias))
          regs
      in
      if to_prune <> [] then save_registrations t to_keep;
      to_prune)

  (** [registry_prune_preview t ~managed_session_ids ~patterns] — read-only preview
      of what [registry_prune] would remove. Same classification logic but does NOT
      save the updated registry. Use for dry-run. *)
  let registry_prune_preview t ~managed_session_ids ~patterns =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let is_test_pattern alias =
        List.exists (fun prefix ->
          String.length alias >= String.length prefix
          && String.sub alias 0 (String.length prefix) = prefix)
          patterns
      in
      List.filter (fun reg ->
        (* Exclude managed sessions *)
        (not (List.mem reg.session_id managed_session_ids))
        (* Only include dead registrations matching test patterns *)
        && (not (is_sweep_keepable reg))
        && is_test_pattern reg.alias)
        regs)

  (** [deregister t ~alias] — remove a registration by alias.
      Returns [Some reg] if found and removed, [None] if no registration
      matches (dead or alive). Uses the same registry lock + save as sweep. *)
  let deregister t ~alias =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let target = alias_casefold alias in
      match List.find_opt
              (fun reg -> alias_casefold reg.alias = target)
              regs with
      | None -> None
      | Some found ->
          let remaining =
            List.filter
              (fun reg -> alias_casefold reg.alias <> target)
              regs
          in
          save_registrations t remaining;
          Some found)

  (* Scan dead-letter.jsonl for records belonging to this session and return
     them for redelivery, removing matched records from the file.
     Called on re-registration so a session that was swept between outer-loop
     iterations automatically recovers messages that were queued while it was
     offline.  Returns [] when the dead-letter file doesn't exist or has no
     matching records.

     Matching rules (OR):
     1. from_session_id == session_id   — exact match; covers managed sessions
        with a stable C2C_MCP_SESSION_ID (kimi-local, opencode-local, codex).
     2. message.to_alias == alias       — alias match; covers Claude Code which
        keeps a stable alias but gets a fresh CLAUDE_SESSION_ID on every restart. *)
  let drain_dead_letter_for_session t ~session_id ~alias =
    let path = dead_letter_path t in
    (* Fast path: no file → nothing to do *)
    let exists = (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false) in
    if not exists then []
    else
      with_dead_letter_lock t (fun () ->
        let all_lines =
          try
            let ic = open_in path in
            Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let buf = ref [] in
              (try while true do buf := input_line ic :: !buf done
               with End_of_file -> ());
              List.rev !buf)
          with _ -> []
        in
        let to_redeliver = ref [] in
        let to_keep = ref [] in
        List.iter (fun line ->
          let trimmed = String.trim line in
          if trimmed = "" then ()
          else
            let keep =
              try
                let json = Yojson.Safe.from_string trimmed in
                let msg_json = Yojson.Safe.Util.member "message" json in
                let sid_json = Yojson.Safe.Util.member "from_session_id" json in
                let to_alias_json = Yojson.Safe.Util.member "to_alias" msg_json in
                let matches =
                  (match sid_json with
                   | `String sid -> sid = session_id
                   | _ -> false)
                  ||
                  (match to_alias_json with
                   | `String ta -> ta = alias
                   | _ -> false)
                in
                if matches then
                  (try
                     let msg = message_of_json msg_json in
                     to_redeliver := msg :: !to_redeliver;
                     false
                   with _ ->
                     (* If a matching record is malformed, keep it in
                        dead-letter instead of silently dropping content we
                        failed to redeliver. *)
                     true)
                else true
              with _ -> true
            in
            if keep then to_keep := line :: !to_keep
        ) all_lines;
        (* Rewrite the file with only the kept records *)
        (try
          let oc = open_out path in
          Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
            List.iter (fun line ->
              output_string oc line;
              output_char oc '\n'
            ) (List.rev !to_keep))
        with _ -> ());
        List.rev !to_redeliver)

  (* Enqueue a list of messages directly into a session's inbox by session_id,
     bypassing alias resolution.  Used for dead-letter redelivery where the
     session may have re-registered with a different alias. *)
  let enqueue_by_session_id t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_inbox_lock t ~session_id (fun () ->
          let current = load_inbox t ~session_id in
          save_inbox t ~session_id (current @ messages))

  let enqueue_session_message t ~from_alias ~session_id ~content ?(ephemeral = false) () =
    let session_id =
      match validate_session_id session_id with
      | Ok sid -> sid
      | Error msg -> invalid_arg msg
    in
    if is_reserved_system_alias from_alias then
      invalid_arg
        (Printf.sprintf
           "send rejected: from_alias '%s' is a reserved system alias"
           from_alias)
    else
      let message =
        { from_alias
        ; to_alias = session_id
        ; content
        ; deferrable = false
        ; reply_via = None
        ; enc_status = None
        ; ts = Unix.gettimeofday ()
        ; ephemeral
        ; message_id = Some (generate_msg_id ())
        ; pow_difficulty = None
        }
      in
      enqueue_by_session_id t ~session_id ~messages:[ message ]

  let redeliver_dead_letter_for_session t ~session_id ~alias =
    let msgs = drain_dead_letter_for_session t ~session_id ~alias in
    if msgs <> [] then enqueue_by_session_id t ~session_id ~messages:msgs;
    List.length msgs

  (* Read orphan inbox messages for a session without deleting.
     Returns [] when the orphan inbox does not exist or is empty.
     The orphan inbox is the session's inbox file — it is an "orphan" when
     the session has no live registration (e.g. between c2c restart's old
     outer-loop exit and new outer-loop registration). *)
  let read_orphan_inbox_messages t ~session_id =
    let path = inbox_path t ~session_id in
    let exists =
      (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false)
    in
    if not exists then []
    else with_inbox_lock t ~session_id (fun () -> load_inbox t ~session_id)

  (* Atomically read and delete the orphan inbox for a session.
     Used by cmd_restart to capture orphan messages: holds the inbox lock
     across read+delete so a concurrent enqueue cannot race between them. *)
  let read_and_delete_orphan_inbox t ~session_id =
    let path = inbox_path t ~session_id in
    let exists =
      (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false)
    in
    if not exists then []
    else
      with_inbox_lock t ~session_id (fun () ->
        let msgs = load_inbox t ~session_id in
        ignore (try_unlink path);
        msgs)

  (* Capture orphan inbox messages for restart: atomically read the orphan inbox,
     write a pending replay file, and delete the orphan — all under the inbox
     lock.  The pending file is written BEFORE the inbox is deleted, so a write
     failure leaves the orphan intact (not partially-captured).  Holds the
     inbox lock across all three steps (read, write, delete) to prevent any
     concurrent enqueue from racing.
     Returns the number of messages captured, or 0 if no orphan existed. *)
  let capture_orphan_for_restart t ~session_id =
    let inbox_path = inbox_path t ~session_id in
    let pending_path =
      Filename.concat t.root ("pending-orphan-replay." ^ session_id ^ ".json")
    in
    let orphan_exists =
      (try ignore (Unix.stat inbox_path); true with Unix.Unix_error _ -> false)
    in
    if not orphan_exists then 0
    else
      with_inbox_lock t ~session_id (fun () ->
        let msgs = load_inbox t ~session_id in
        if msgs = [] then (
          (* Empty orphan — delete it so it doesn't persist across restarts *)
          ignore (try_unlink inbox_path);
          0
        ) else (
          (* Write pending replay file BEFORE deleting the orphan.
             Atomic write: write to tmp, fsync, rename. *)
          let tmp = pending_path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
          (* Not append_jsonl: atomic-replace write-to-tmp + rename. *)
          let oc = open_out_gen
            [Open_wronly; Open_creat; Open_trunc; Open_text] 0o600 tmp
          in
           (try
             Fun.protect
               ~finally:(fun () -> try close_out oc with _ -> ())
               (fun () -> Yojson.Safe.to_channel oc (`List (List.map (fun m ->
                 `Assoc [
                   ("from_alias", `String m.from_alias);
                   ("to_alias", `String m.to_alias);
                   ("content", `String m.content);
                   ("deferrable", `Bool m.deferrable);
                   ("reply_via", match m.reply_via with None -> `Null | Some s -> `String s);
                   ("enc_status", match m.enc_status with None -> `Null | Some s -> `String s);
                 ]) msgs)))
            with e ->
              ignore (try_unlink tmp);
              raise e);
          (try Unix.rename tmp pending_path
           with e ->
             ignore (try_unlink tmp);
             raise e);
          ignore (try_unlink inbox_path);
          List.length msgs
        ))

  (* Replay captured orphan messages into the new session's inbox.
     Called in the MCP server after auto_register_startup completes, so
     messages queued during the restart gap (between old outer-loop exit and
     new registration) are delivered to the new session.
     The pending replay file is at broker_root/pending-orphan-replay.<session_id>.json. *)
  let replay_pending_orphan_inbox t ~session_id =
    let pending_path =
      Filename.concat t.root ("pending-orphan-replay." ^ session_id ^ ".json")
    in
    if not (Sys.file_exists pending_path) then 0
    else
      (* Slice F + follow-up: inline size check with audit event on cap
         exceeded (fern non-blocking note). *)
      let content = C2c_io.read_file_opt pending_path in
      let pending_json =
        if String.length content > 65536 then begin
          log_json_cap_exceeded ~broker_root:t.root ~path:pending_path ~max_bytes:65536;
          `List []
        end else
          (try Yojson.Safe.from_string content with _ -> `List [])
      in
      let msgs =
        match pending_json with
        | `List items ->
            List.map (fun json ->
              let open Yojson.Safe.Util in
              { from_alias = json |> member "from_alias" |> to_string
              ; to_alias = json |> member "to_alias" |> to_string
              ; content = json |> member "content" |> to_string
              ; deferrable =
                  (match json |> member "deferrable" with `Bool b -> b | _ -> false)
              ; reply_via =
                  (match json |> member "reply_via" with `String s -> Some s | _ -> None)
              ; enc_status =
                  (match json |> member "enc_status" with `String s -> Some s | _ -> None)
              ; ts =
                  (match json |> member "ts" with
                   | `Float f -> f | `Int i -> float_of_int i | _ -> 0.0)
              ; ephemeral =
                  (match json |> member "ephemeral" with `Bool b -> b | _ -> false)
              ; message_id =
                  (match json |> member "message_id" with
                   | `String s when s <> "" -> Some s | _ -> None)
              ; pow_difficulty = pow_difficulty_of_json json
              }) items
        | _ -> []
      in
      if msgs = [] then begin
        (try Unix.unlink pending_path with _ -> ());
        0
      end else begin
        (* Hold the inbox lock across read+save so a concurrent enqueue
           during MCP startup cannot overwrite our appended messages. *)
        with_inbox_lock t ~session_id (fun () ->
          let current = read_inbox t ~session_id in
          save_inbox t ~session_id (current @ msgs));
        (try Unix.unlink pending_path with _ -> ());
        List.length msgs
      end

  (* ---------- N:N rooms (phase 2) ---------- *)

  let valid_room_id room_id =
    room_id <> ""
    && String.for_all
         (fun c ->
           (c >= 'a' && c <= 'z')
           || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9')
           || c = '-' || c = '_')
         room_id

  let rooms_dir t = Filename.concat t.root "rooms"

  let room_dir t ~room_id = Filename.concat (rooms_dir t) room_id

  let room_members_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "members.json"

  let room_history_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "history.jsonl"

  let room_members_lock_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "members.lock"

  let room_history_lock_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "history.lock"

  let ensure_room_dir t ~room_id =
    ensure_root t;
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then Unix.mkdir rd 0o755;
    let d = room_dir t ~room_id in
    if not (Sys.file_exists d) then Unix.mkdir d 0o755

  let with_room_members_lock t ~room_id f =
    ensure_room_dir t ~room_id;
    let fd =
      Unix.openfile (room_members_lock_path t ~room_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let with_room_history_lock t ~room_id f =
    ensure_room_dir t ~room_id;
    let fd =
      Unix.openfile (room_history_lock_path t ~room_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let room_member_to_json { rm_alias; rm_session_id; joined_at } =
    `Assoc
      [ ("alias", `String rm_alias)
      ; ("session_id", `String rm_session_id)
      ; ("joined_at", `Float joined_at)
      ]

  let room_member_of_json json =
    let open Yojson.Safe.Util in
    { rm_alias = json |> member "alias" |> to_string
    ; rm_session_id = json |> member "session_id" |> to_string
    ; joined_at = json |> member "joined_at" |> to_number
    }

  let load_room_members t ~room_id =
    ensure_room_dir t ~room_id;
    match read_json_file ~broker_root:t.root (room_members_path t ~room_id) ~default:(`List []) with
    | `List items -> List.map room_member_of_json items
    | _ -> []

  let save_room_members t ~room_id members =
    ensure_room_dir t ~room_id;
    write_json_file (room_members_path t ~room_id)
      (`List (List.map room_member_to_json members))

  let room_meta_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "meta.json"

  let room_visibility_to_json = function
    | Public -> `String "public"
    | Unlisted -> `String "unlisted"
    | Gated -> `String "gated"
    | Private -> `String "private"

  let room_visibility_of_json json =
    match json with
    | `String "public" -> Public
    | `String "unlisted" -> Unlisted
    | `String "gated" -> Gated
    | `String "private" -> Private
    (* Absent field (`Null): a legacy room from before visibility existed —
       public by design. A PRESENT but unrecognized value (e.g. a legacy
       "invite"/"invite_only" string) fails SAFE to Private rather than
       silently exposing a previously-restricted room. *)
    | `Null -> Public
    | _ -> Private

  let room_knock_to_json { requester_alias; requested_at } =
    `Assoc
      [ ("requester_alias", `String requester_alias)
      ; ("requested_at", `Float requested_at)
      ]

  let room_knock_of_json json =
    let open Yojson.Safe.Util in
    { requester_alias =
        (try
           match member "requester_alias" json with
           | `String s -> s
           | _ -> ""
         with _ -> "")
    ; requested_at =
        (try
           match member "requested_at" json with
           | `Float f -> f
           | `Int i -> float_of_int i
           | _ -> 0.0
         with _ -> 0.0)
    }

  let room_meta_to_json { visibility; invited_members; pending_knocks; created_by } =
    `Assoc
      [ ("visibility", room_visibility_to_json visibility)
      ; ("invited_members", `List (List.map (fun s -> `String s) invited_members))
      ; ("pending_knocks", `List (List.map room_knock_to_json pending_knocks))
      ; ("created_by", `String created_by)
      ]

  let room_meta_of_json json =
    let open Yojson.Safe.Util in
    { visibility =
        (try room_visibility_of_json (member "visibility" json) with _ -> Public)
    ; invited_members =
        (try
           match member "invited_members" json with
           | `List items ->
               List.filter_map
                 (function `String s -> Some s | _ -> None)
                 items
           | _ -> []
         with _ -> [])
    ; pending_knocks =
        (try
           match member "pending_knocks" json with
           | `List items ->
               items
               |> List.filter_map
                    (fun item ->
                       let knock = room_knock_of_json item in
                       if knock.requester_alias = "" then None else Some knock)
           | _ -> []
         with _ -> [])
    ; created_by =
        (try
           match member "created_by" json with
           | `String s -> s
           | _ -> ""
         with _ -> "")
    }

  let load_room_meta t ~room_id =
    ensure_room_dir t ~room_id;
    match read_json_file ~broker_root:t.root (room_meta_path t ~room_id) ~default:(`Assoc []) with
    | `Assoc _ as json -> room_meta_of_json json
    | _ -> { visibility = Public; invited_members = []; pending_knocks = []; created_by = "" }

  let save_room_meta t ~room_id meta =
    ensure_room_dir t ~room_id;
    write_json_file (room_meta_path t ~room_id) (room_meta_to_json meta)

  let room_system_alias = "c2c-system"

  let room_join_content ~alias ~room_id = alias ^ " joined room " ^ room_id
  let room_leave_content ~alias ~room_id = alias ^ " left room " ^ room_id

  let append_room_history_unchecked t ~room_id ~from_alias ~content =
    let ts = Unix.gettimeofday () in
    with_room_history_lock t ~room_id (fun () ->
        (* Not broker.log: room-history append, not append_jsonl target. *)
        let oc =
          open_out_gen
            [ Open_wronly; Open_append; Open_creat ]
            0o600 (room_history_path t ~room_id)
        in
        Fun.protect
          ~finally:(fun () -> try close_out oc with _ -> ())
          (fun () ->
            let record =
              `Assoc
                [ ("ts", `Float ts)
                ; ("from_alias", `String from_alias)
                ; ("content", `String content)
                ]
            in
            output_string oc (Yojson.Safe.to_string record);
            output_char oc '\n'));
    ts

  let fan_out_room_message ?(tag : string option) t ~room_id ~from_alias ~content =
    (* #392 slice 4: optional tag → per-recipient body prefix. The prefix
       lands in the inbox row only, NOT in [content] passed to history
       dedup at the [send_room] caller. This keeps "same body, different
       tag" from bypassing dedup (sender re-tagging an already-sent
       message should still be dropped) while letting each recipient
       transcript surface the visual indicator. *)
    let prefixed_content = match tag with
      | Some t when t <> "" -> tag_to_body_prefix (Some t) ^ content
      | _ -> content
    in
    let members =
      with_room_members_lock t ~room_id (fun () ->
          load_room_members t ~room_id)
    in
    let delivered = ref [] in
    let skipped = ref [] in
    List.iter
      (fun m ->
         if m.rm_alias = from_alias then ()
         else begin
           let tagged_to = m.rm_alias ^ "#" ^ room_id in
           try
             with_registry_lock t (fun () ->
                 match resolve_live_session_id_by_alias t m.rm_alias with
                 | Resolved session_id ->
                     with_inbox_lock t ~session_id (fun () ->
                         let current = load_inbox t ~session_id in
                         let next =
                            current @ [ { from_alias; to_alias = tagged_to; content = prefixed_content; deferrable = false; reply_via = None; enc_status = None; ts = Unix.gettimeofday (); ephemeral = false; message_id = None; pow_difficulty = None } ]
                         in
                         save_inbox t ~session_id next);
                     delivered := m.rm_alias :: !delivered
                 | All_recipients_dead | Unknown_alias ->
                     skipped := m.rm_alias :: !skipped)
           with _ ->
             skipped := m.rm_alias :: !skipped
         end)
      members;
    (List.rev !delivered, List.rev !skipped)

  let broadcast_room_join t ~room_id ~alias =
    let content = room_join_content ~alias ~room_id in
    ignore (append_room_history_unchecked t ~room_id ~from_alias:room_system_alias ~content);
    ignore (fan_out_room_message t ~room_id ~from_alias:room_system_alias ~content)

  let broadcast_room_leave t ~room_id ~alias =
    let content = room_leave_content ~alias ~room_id in
    ignore (append_room_history_unchecked t ~room_id ~from_alias:room_system_alias ~content);
    ignore (fan_out_room_message t ~room_id ~from_alias:room_system_alias ~content)

  let join_room t ~room_id ~alias ~session_id =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let meta = load_room_meta t ~room_id in
    let current_members = load_room_members t ~room_id in
    let already_member =
      List.exists
        (fun m -> m.rm_alias = alias || m.rm_session_id = session_id)
        current_members
    in
    let invite_gated = meta.visibility = Gated || meta.visibility = Private in
    if invite_gated && not already_member then
      if not (List.mem alias meta.invited_members) then
        invalid_arg
          ("join_room rejected: room '" ^ room_id ^ "' requires an invite and '" ^ alias ^ "' is not on the invite list");
    (* H3 rooms-acl: stamp [created_by] when the joiner is establishing the
       room (no members yet, no creator recorded). Subsequent joiners do
       not overwrite. Legacy rooms (members exist, created_by="") stay
       empty and require [~force:true] to delete. *)
    (if current_members = [] && meta.created_by = "" then
       (* #alias-casefold: store [created_by] as canonical-lowercase so
          legacy mixed-case-storage DoS cannot occur for new rooms. The
          read-side casefold in [delete_room] still handles legacy rows
          stored before this change. *)
       save_room_meta t ~room_id { meta with created_by = alias_casefold alias });
    let updated, should_broadcast =
      with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        (* Same alias with a new session_id is a restart. Same session_id with
           a new alias is a rename. In both cases there must be only one member
           row, otherwise room fanout and social presence duplicate the peer. *)
        let existing =
          List.find_opt
            (fun m -> m.rm_alias = alias || m.rm_session_id = session_id)
            members
        in
        let exact_existing =
          match existing with
          | Some m when m.rm_alias = alias && m.rm_session_id = session_id ->
              true
          | _ -> false
        in
        let joined_at =
          match existing with
          | Some m -> m.joined_at
          | None -> Unix.gettimeofday ()
        in
        let member = { rm_alias = alias; rm_session_id = session_id; joined_at } in
        if exact_existing then (members, false)
        else
          let rec replace inserted = function
            | [] -> if inserted then [] else [ member ]
            | m :: rest
              when m.rm_alias = alias || m.rm_session_id = session_id ->
                if inserted then replace true rest
                else member :: replace true rest
            | m :: rest -> m :: replace inserted rest
          in
          let updated = replace false members in
          if updated <> members then save_room_members t ~room_id updated;
          (updated, updated <> members))
    in
    let unconfirmed =
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | Some reg -> is_unconfirmed reg
      | None -> false
    in
    if should_broadcast && not unconfirmed then broadcast_room_join t ~room_id ~alias;
    updated

  let leave_room t ~room_id ~alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let should_broadcast, updated =
      with_room_members_lock t ~room_id (fun () ->
          let members = load_room_members t ~room_id in
          let updated = List.filter (fun m -> m.rm_alias <> alias) members in
          save_room_members t ~room_id updated;
          (updated <> members, updated))
    in
    if should_broadcast then broadcast_room_leave t ~room_id ~alias;
    updated

  (* Delete a room entirely. Fails if the room has any members.
     H3 rooms-acl: also requires caller-auth — only the room creator
     ([meta.created_by]) may delete. Legacy rooms (created_by="")
     require [~force:true] from the caller, intended as an operator
     escape hatch for rooms whose meta predates the field. *)
  let delete_room t ~room_id ?(caller_alias = "") ?(force = false) () =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let dir = room_dir t ~room_id in
    if not (Sys.file_exists dir) then
      invalid_arg ("room does not exist: " ^ room_id);
    let meta = load_room_meta t ~room_id in
    (if meta.created_by = "" then begin
       if not force then
         invalid_arg
           ("delete_room rejected: room '" ^ room_id
            ^ "' has no recorded creator (legacy room) — pass force=true to delete")
     end
     else if alias_casefold caller_alias <> alias_casefold meta.created_by then
       (* #alias-casefold: legitimate creator stored as "Alice" (legacy)
          should still be able to delete their own room when their
          session resolves the alias as "alice". Direction-safe: the
          attacker cannot impersonate another identity because
          [send_alias_impersonation_check] (in the MCP handler) already
          rejects when caller_alias is held by a live different session. *)
       invalid_arg
         ("delete_room rejected: only the creator '" ^ meta.created_by
          ^ "' may delete room '" ^ room_id ^ "'"));
    (* Hold both locks while checking members and deleting the directory. *)
    with_room_members_lock t ~room_id (fun () ->
      with_room_history_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        if members <> [] then
          invalid_arg ("cannot delete room with members: " ^ room_id);
        (* Delete all files in the room directory, then the directory itself. *)
        let files = Sys.readdir dir in
        Array.iter
          (fun f ->
            try Unix.unlink (Filename.concat dir f) with Unix.Unix_error _ -> ())
          files;
        try Unix.rmdir dir with Unix.Unix_error _ -> ()))

  (* Room-event auto-DM envelopes route peer-controlled alias/room values
     through [xml_escape] (the canonical H2a untrusted-data renderer) so a
     hostile alias or room id cannot inject a closing [</c2c>], a forged
     [<system-reminder>], or an attribute breakout into the delivered
     envelope. Aliases and room ids are charset-validated at their entry
     points, so this is defence-in-depth — but it keeps every string-into-
     markup site on the same escaping contract as [format_c2c_envelope]. *)
  let render_room_invite_envelope ~from_alias ~room_id =
    let f = xml_escape from_alias and r = xml_escape room_id in
    Printf.sprintf
      "<c2c event=\"room-invite\" from=\"%s\" room=\"%s\">You've been \
       invited to room %s by %s. Run `c2c rooms join %s` to accept.</c2c>"
      f r r f r

  let render_room_knock_envelope ~requester_alias ~room_id =
    let q = xml_escape requester_alias and r = xml_escape room_id in
    Printf.sprintf
      "<c2c event=\"room-knock\" from=\"%s\" room=\"%s\">%s wants \
       to join room %s. Run `c2c rooms approve-knock %s %s` to \
       approve, or `c2c rooms deny-knock %s %s` to deny.</c2c>"
      q r q r r q r q

  let send_room_invite t ~room_id ~from_alias ~invitee_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    let is_member = List.exists (fun m -> m.rm_alias = from_alias) members in
    if not is_member then
      invalid_arg ("send_room_invite rejected: only room members can invite");
    let meta = load_room_meta t ~room_id in
    let was_already_invited = List.mem invitee_alias meta.invited_members in
    if not was_already_invited then
      save_room_meta t ~room_id
        { meta with invited_members = meta.invited_members @ [ invitee_alias ] };
    (* #433: auto-DM the invitee so they actually learn about the invite.
       Prior behaviour was ACL-append-only (silent — no notification). The
       envelope uses event="room-invite" so client-side Monitors can route
       it distinctly from ordinary message DMs. We re-DM even on duplicate
       invites: a duplicate invite is a deliberate nudge and should reach
       the invitee (cheap; ACL itself stays idempotent). *)
    let envelope = render_room_invite_envelope ~from_alias ~room_id in
    (* Sender is the inviter (real alias) rather than the reserved
       [room_system_alias], because [enqueue_message] rejects
       reserved system aliases as a spoof guard (see
       [reserved_system_aliases]). The envelope's [from="..."] attr
       already names the inviter, and using a real alias keeps the
       DM addressable for replies. Best-effort: swallow errors so
       the ACL append remains the primary success path. *)
    (try
       enqueue_message t ~from_alias ~to_alias:invitee_alias
         ~content:envelope ()
     with _ -> ())

  type knock_room_result =
    { kr_room_id : string
    ; kr_requester_alias : string
    ; kr_already_pending : bool
    ; kr_notified : string list
    }

  let alias_mem_casefold alias aliases =
    let target = alias_casefold alias in
    List.exists (fun a -> alias_casefold a = target) aliases

  let room_has_member_alias members alias =
    let target = alias_casefold alias in
    List.exists (fun m -> alias_casefold m.rm_alias = target) members

  let remove_pending_knock pending requester_alias =
    let target = alias_casefold requester_alias in
    List.filter
      (fun (k : room_knock) -> alias_casefold k.requester_alias <> target)
      pending

  let hidden_or_no_knocks_error =
    "knock_room rejected: room is not discoverable or does not accept knocks"

  let knock_room t ~room_id ~requester_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let dir = room_dir t ~room_id in
    if not (Sys.file_exists dir) then
      invalid_arg hidden_or_no_knocks_error;
    let meta = load_room_meta t ~room_id in
    let members = load_room_members t ~room_id in
    (match meta.visibility with
     | Public ->
         invalid_arg
           ("knock_room rejected: room '" ^ room_id ^ "' is public; join directly")
     | Unlisted ->
         invalid_arg
           ("knock_room rejected: room '" ^ room_id ^ "' is unlisted; join directly")
     | Private ->
         invalid_arg hidden_or_no_knocks_error
     | Gated ->
         if room_has_member_alias members requester_alias then
           invalid_arg
             ("knock_room rejected: '" ^ requester_alias
              ^ "' is already a member of room '" ^ room_id ^ "'");
         if alias_mem_casefold requester_alias meta.invited_members then
           invalid_arg
             ("knock_room rejected: '" ^ requester_alias
              ^ "' is already invited to room '" ^ room_id ^ "'");
         let already_pending =
           List.exists
             (fun (k : room_knock) ->
                alias_casefold k.requester_alias = alias_casefold requester_alias)
             meta.pending_knocks
         in
         if already_pending then
           { kr_room_id = room_id
           ; kr_requester_alias = requester_alias
           ; kr_already_pending = true
           ; kr_notified = []
           }
         else begin
           let knock =
             { requester_alias; requested_at = Unix.gettimeofday () }
           in
           save_room_meta t ~room_id
             { meta with pending_knocks = meta.pending_knocks @ [ knock ] };
           let notified = ref [] in
           let envelope = render_room_knock_envelope ~requester_alias ~room_id in
           List.iter
             (fun (m : room_member) ->
                if alias_casefold m.rm_alias = alias_casefold requester_alias
                then ()
                else
                  try
                    enqueue_message t ~from_alias:requester_alias
                      ~to_alias:m.rm_alias ~content:envelope ();
                    notified := m.rm_alias :: !notified
                  with _ -> ())
             members;
           { kr_room_id = room_id
           ; kr_requester_alias = requester_alias
           ; kr_already_pending = false
           ; kr_notified = List.rev !notified
           }
         end)

  let list_room_knocks t ~room_id ~caller_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    if not (room_has_member_alias members caller_alias) then
      invalid_arg "list_room_knocks rejected: only room members can list knocks";
    let meta = load_room_meta t ~room_id in
    meta.pending_knocks

  let approve_room_knock t ~room_id ~approver_alias ~requester_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    if not (room_has_member_alias members approver_alias) then
      invalid_arg "approve_room_knock rejected: only room members can approve knocks";
    let meta = load_room_meta t ~room_id in
    let target = alias_casefold requester_alias in
    let had_pending =
      List.exists
        (fun (k : room_knock) -> alias_casefold k.requester_alias = target)
        meta.pending_knocks
    in
    if not had_pending then
      invalid_arg
        ("approve_room_knock rejected: no pending knock from '" ^ requester_alias
         ^ "' in room '" ^ room_id ^ "'");
    send_room_invite t ~room_id ~from_alias:approver_alias
      ~invitee_alias:requester_alias;
    let latest = load_room_meta t ~room_id in
    save_room_meta t ~room_id
      { latest with
        pending_knocks = remove_pending_knock latest.pending_knocks requester_alias
      }

  let deny_room_knock t ~room_id ~denier_alias ~requester_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    if not (room_has_member_alias members denier_alias) then
      invalid_arg "deny_room_knock rejected: only room members can deny knocks";
    let meta = load_room_meta t ~room_id in
    let target = alias_casefold requester_alias in
    let had_pending =
      List.exists
        (fun (k : room_knock) -> alias_casefold k.requester_alias = target)
        meta.pending_knocks
    in
    if not had_pending then
      invalid_arg
        ("deny_room_knock rejected: no pending knock from '" ^ requester_alias
         ^ "' in room '" ^ room_id ^ "'");
    save_room_meta t ~room_id
      { meta with pending_knocks = remove_pending_knock meta.pending_knocks requester_alias }

  let set_room_visibility t ~room_id ~from_alias ~visibility =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    let is_member = List.exists (fun m -> m.rm_alias = from_alias) members in
    if not is_member then
      invalid_arg ("set_room_visibility rejected: only room members can change visibility");
    let meta = load_room_meta t ~room_id in
    save_room_meta t ~room_id { meta with visibility }

  type create_room_result =
    { cr_room_id : string
    ; cr_created_by : string
    ; cr_visibility : room_visibility
    ; cr_invited_members : string list
    ; cr_members : string list
    ; cr_auto_joined : bool
    }

  (* #394: explicit room creation with visibility-on-create. Lineage:
     #385/H3 + #M4 covered the visibility-on-create path through join_room
     for MCP callers; this surface gives CLI users a create-without-join
     entry point with the same atomicity guarantee. *)
  let create_room t ~room_id ~caller_alias ~caller_session_id ~visibility
        ~invited_members ~auto_join =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let dir = room_dir t ~room_id in
    (* #403: rely solely on mkdir(2)'s atomic EEXIST. The previous
       Sys.file_exists pre-check was a real TOCTOU window — two creators
       could both pass the check and then race on mkdir, with the loser
       getting "room already exists" only if it happened to lose the
       mkdir race AS WELL. Worse, the pre-check was misleading: it
       suggested the create was guarded, but the mkdir below was the
       only actual atomic guard. Drop the misleading check; let mkdir
       be the single authority. *)
    (try Unix.mkdir (rooms_dir t) 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    (try Unix.mkdir dir 0o700
     with Unix.Unix_error (Unix.EEXIST, _, _) ->
       invalid_arg ("room already exists: " ^ room_id));
    let dedup_invited =
      List.fold_left
        (fun acc a -> if List.mem a acc then acc else acc @ [ a ])
        [] invited_members
    in
    save_room_meta t ~room_id
      (* #alias-casefold: store [created_by] as canonical-lowercase
         (defense-in-depth, matches the join-time stamp at the other
         creation site). *)
      { visibility; invited_members = dedup_invited; pending_knocks = [];
        created_by = alias_casefold caller_alias };
    let members =
      if auto_join then begin
        let member =
          { rm_alias = caller_alias
          ; rm_session_id = caller_session_id
          ; joined_at = Unix.gettimeofday ()
          }
        in
        save_room_members t ~room_id [ member ];
        [ caller_alias ]
      end
      else []
    in
    { cr_room_id = room_id
    ; cr_created_by = caller_alias
    ; cr_visibility = visibility
    ; cr_invited_members = dedup_invited
    ; cr_members = members
    ; cr_auto_joined = auto_join
    }

  let rename_room_member_alias t ~room_id ~session_id ~new_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        match List.find_opt (fun m -> m.rm_session_id = session_id) members with
        | None -> members
        | Some existing ->
            let renamed = { existing with rm_alias = new_alias } in
            let without_session =
              List.filter (fun m -> m.rm_session_id <> session_id) members
            in
            let updated = without_session @ [ renamed ] in
            save_room_members t ~room_id updated;
            updated)

  (* Evict dead sessions from all room member lists.  Called as part of
     the sweep tool so dead sessions don't linger as room members after
     their registration is dropped.  Sessions with a live outer loop
     re-join automatically via C2C_MCP_AUTO_JOIN_ROOMS on restart.
     Returns a list of (room_id, alias) pairs that were evicted.

     Uses BOTH session_id and alias matching to handle the case where
     a room member was added with one session_id but the registration
     later re-registered with a different session_id (common with
     managed outer loops that reuse the same alias). *)
  let evict_dead_from_rooms t ~dead_session_ids ~dead_aliases =
    let dead_keys = dead_session_ids in
    let should_evict m =
      List.mem m.rm_session_id dead_keys
      || List.mem m.rm_alias dead_aliases
    in
    if dead_session_ids = [] && dead_aliases = [] then []
    else begin
      let rd = rooms_dir t in
      if not (Sys.file_exists rd) then []
      else begin
        let room_names =
          try
            Array.to_list (Sys.readdir rd)
            |> List.filter (fun name ->
                   Sys.is_directory (Filename.concat rd name))
          with _ -> []
        in
        let evicted = ref [] in
        List.iter (fun room_id ->
          with_room_members_lock t ~room_id (fun () ->
            let members = load_room_members t ~room_id in
            let kept, removed =
              List.partition (fun m -> not (should_evict m)) members
            in
            if removed <> [] then begin
              save_room_members t ~room_id kept;
              List.iter
                (fun m -> evicted := (room_id, m.rm_alias) :: !evicted)
                removed
            end))
          room_names;
        !evicted
      end
    end

  let orphan_room_members t regs =
    let has_registration member =
      List.exists
        (fun reg ->
          reg.session_id = member.rm_session_id || reg.alias = member.rm_alias)
        regs
    in
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else
      let room_names =
        try
          Array.to_list (Sys.readdir rd)
          |> List.filter (fun name ->
                 Sys.is_directory (Filename.concat rd name))
        with _ -> []
      in
      room_names
      |> List.concat_map (fun room_id ->
             load_room_members t ~room_id
             |> List.filter (fun member -> not (has_registration member)))

  (* Evict dead members from rooms without touching registrations or inboxes.
     Safe to call while outer loops are running (unlike sweep). *)
  let prune_rooms t =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      (* Use tristate liveness: treat Unknown as Dead for pidless rows (pid=None),
         since they cannot be verified alive and accumulate dead fan-out messages.
         However, Unknown rows with a set PID (pid_start_time missing but process
         may exist) are treated conservatively — do NOT evict, since the process
         might still be alive. registration_is_alive collapses Unknown→Alive for
         backward-compat with sweep/enqueue delivery. *)
      let dead_regs =
        regs
        |> List.filter (fun r ->
               match registration_liveness_state r with
               | Alive -> false
               | Dead -> true
               | Unknown -> Option.is_none r.pid)
      in
      let orphan_members = orphan_room_members t regs in
      let dead_sids =
        List.map (fun r -> r.session_id) dead_regs
        @ List.map (fun m -> m.rm_session_id) orphan_members
      in
      let dead_aliases =
        List.map (fun r -> r.alias) dead_regs
        @ List.map (fun m -> m.rm_alias) orphan_members
      in
      evict_dead_from_rooms t ~dead_session_ids:dead_sids ~dead_aliases)

  (* Public alias for tests and external callers. *)
  let read_room_members = load_room_members

  let append_room_history t ~room_id ~from_alias ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    append_room_history_unchecked t ~room_id ~from_alias ~content

  let read_room_history t ~room_id ~limit ?(since = 0.0) () =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let path = room_history_path t ~room_id in
    if not (Sys.file_exists path) then []
    else begin
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let lines = ref [] in
          (try
             while true do
               let line = input_line ic in
               if line <> "" then
                 lines := line :: !lines
             done
           with End_of_file -> ());
          let all = List.rev !lines in
          (* Filter by timestamp before applying limit *)
          let filtered =
            if since <= 0.0 then all
            else List.filter (fun line ->
              try
                let json = Yojson.Safe.from_string line in
                let ts = Yojson.Safe.Util.(json |> member "ts" |> to_number) in
                ts >= since
              with _ -> true
            ) all
          in
          let n = List.length filtered in
          let to_take = if limit <= 0 then n else min limit n in
          let start = n - to_take in
          let taken =
            List.filteri (fun i _ -> i >= start) filtered
          in
          List.map
            (fun line ->
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              { rm_from_alias = json |> member "from_alias" |> to_string
              ; rm_room_id = room_id
              ; rm_content = json |> member "content" |> to_string
              ; rm_ts = json |> member "ts" |> to_number
              })
            taken)
    end

  type send_room_result =
    { sr_delivered_to : string list
    ; sr_skipped : string list
    ; sr_ts : float
    ; sr_warning : string option  (* non-fatal warning, e.g. room had 0 members *)
    }

  (* Suppress byte-identical repeat messages from the same sender within this window. *)
  let room_send_dedup_window_s = 60.0

  let send_room ?(tag : string option) t ~from_alias ~room_id ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    (* #silent-send: check membership and detect ghost room vs left room.
       - Ghost room: room was auto-created by send_room (created_by="", members=[])
         → warn but allow (Bug 2)
       - Left room: room had members, sender was one of them, now not
         → error (Bug 1)
       - Never was a member: room has members but sender is not one
         → error *)
    let members = load_room_members t ~room_id in
    let meta = load_room_meta t ~room_id in
    let sender_is_member = List.exists (fun m -> m.rm_alias = from_alias) members in
    let is_ghost_room = meta.created_by = "" && members = [] in
    let is_system_alias = List.mem from_alias reserved_system_aliases in
    if is_ghost_room then
      (* Ghost room: warn but allow the send. Message goes to history only. *)
      ()
    else if not sender_is_member && not is_system_alias then
      invalid_arg
        ("send_room rejected: " ^ from_alias ^ " is not a member of room " ^ room_id);
    (* Dedup: skip if the same sender just sent the same content within the window.
       #392 slice 4 note: we dedup on BARE content (pre-prefix) so that
       sender re-tagging an already-sent message ("BLOCKING:" instead of
       no tag, or "URGENT:" instead of "BLOCKING:") still counts as a
       duplicate. Tag is purely a presentation concern; the message body
       is what defines "same message." *)
    let now = Unix.gettimeofday () in
    let recent = read_room_history t ~room_id ~limit:20 () in
    let is_dup =
      List.exists
        (fun m ->
          m.rm_from_alias = from_alias
          && m.rm_content = content
          && now -. m.rm_ts < room_send_dedup_window_s)
        recent
    in
    if is_dup then
      { sr_delivered_to = []; sr_skipped = []; sr_ts = now; sr_warning = None }
    else begin
    (* Step 1: append to history (under history lock, released before fan-out.
       History stores BARE content; the per-recipient prefix lives only in
       inbox rows so it's surfaced in the recipient's transcript without
       double-prefixing on a future history-replay. *)
    let ts = append_room_history_unchecked t ~room_id ~from_alias ~content in
    (* Step 2: fan out to each member except sender. For each recipient,
       take registry_lock -> inbox_lock (existing lock order) and enqueue
       with to_alias tagged as "<alias>#<room_id>" so the recipient can
       distinguish room messages from direct messages. The optional [tag]
       prefixes the per-recipient content with [tag_to_body_prefix] so the
       receiving agent sees "🔴 FAIL: ...", "⛔ BLOCKING: ...", or
       "⚠️ URGENT: ..." at the head of the transcript line. *)
    let delivered, skipped =
      fan_out_room_message ?tag t ~room_id ~from_alias ~content
    in
    (* #silent-send Bug 2: warn when room had 0 members at send time.
       This catches the "ghost room" case where send_room auto-created the room
       directory (via ensure_room_dir called by load_room_members above) but
       nobody was in the room — the message went to history but 0 recipients. *)
    let warning =
      if delivered = [] && skipped = [] then
        Some ("room " ^ room_id ^ " has 0 members; message stored in history but not delivered")
      else None
    in
    { sr_delivered_to = delivered
    ; sr_skipped = skipped
    ; sr_ts = ts
    ; sr_warning = warning
    }
    end

  type room_info =
    { ri_room_id : string
    ; ri_member_count : int
    ; ri_members : string list
    ; ri_alive_member_count : int
    ; ri_dead_member_count : int
    ; ri_unknown_member_count : int
    ; ri_member_details : room_member_info list
    ; ri_visibility : room_visibility
    ; ri_invited_members : string list
    }
  and room_member_info =
    { rmi_alias : string
    ; rmi_session_id : string
    ; rmi_alive : bool option
    }

  let room_member_liveness t members =
    let regs = list_registrations t in
    let find_reg member =
      match
        List.find_opt
          (fun reg -> reg.session_id = member.rm_session_id)
          regs
      with
      | Some reg -> Some reg
      | None -> List.find_opt (fun reg -> reg.alias = member.rm_alias) regs
    in
    List.map
      (fun member ->
        let alive =
          match find_reg member with
          | None -> Some false
          | Some reg ->
              (match reg.pid with
               | None -> None
               | Some _ -> Some (registration_is_alive reg))
        in
        { rmi_alias = member.rm_alias
        ; rmi_session_id = member.rm_session_id
        ; rmi_alive = alive
        })
      members

  let room_info_of_members t ~room_id members =
    let meta = load_room_meta t ~room_id in
    let details = room_member_liveness t members in
    let count_by predicate =
      List.fold_left
        (fun count detail -> if predicate detail.rmi_alive then count + 1 else count)
        0 details
    in
    { ri_room_id = room_id
    ; ri_member_count = List.length members
    ; ri_members = List.map (fun m -> m.rm_alias) members
    ; ri_alive_member_count = count_by (( = ) (Some true))
    ; ri_dead_member_count = count_by (( = ) (Some false))
    ; ri_unknown_member_count = count_by (( = ) None)
    ; ri_member_details = details
    ; ri_visibility = meta.visibility
    ; ri_invited_members = meta.invited_members
    }

  let list_rooms t =
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else begin
      let entries =
        try Sys.readdir rd with Sys_error _ -> [||]
      in
      Array.fold_left
        (fun acc name ->
          let dir_path = Filename.concat rd name in
          if Sys.is_directory dir_path then begin
            let members =
              try load_room_members t ~room_id:name
              with _ -> []
            in
            room_info_of_members t ~room_id:name members :: acc
          end else acc)
        []
        entries
      |> List.rev
    end

  (* Rooms where [session_id] is a member. Keyed on session_id (not alias)
     so a rename stays tracking the same session. Returns the same
     [room_info] shape as [list_rooms], plus the caller's own alias in
     each room they're currently a member of (useful when the caller
     has joined the same room under two aliases via different
     sessions, or when the alias has changed). *)
  let my_rooms t ~session_id =
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else begin
      let entries =
        try Sys.readdir rd with Sys_error _ -> [||]
      in
      Array.fold_left
        (fun acc name ->
          let dir_path = Filename.concat rd name in
          if Sys.is_directory dir_path then begin
            let members =
              try load_room_members t ~room_id:name
              with _ -> []
            in
            if List.exists (fun m -> m.rm_session_id = session_id) members
            then
              room_info_of_members t ~room_id:name members :: acc
            else acc
          end else acc)
        []
        entries
      |> List.rev
    end

  (* Promote an unconfirmed registration to confirmed on first poll_inbox call.
     If the session was previously unconfirmed (confirmed_at=None, non-human),
     emits the deferred peer_register broadcast and any room-join broadcasts that
     were suppressed at register/join time. No-op for already-confirmed sessions.
     Defined after my_rooms, send_room, broadcast_room_join to avoid forward refs. *)
  let confirm_registration t ~session_id =
    let was_unconfirmed = ref false in
    let promo_alias = ref "" in
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let changed = ref false in
        let regs' =
          List.map
            (fun reg ->
              if reg.session_id = session_id && reg.confirmed_at = None then begin
                changed := true;
                if is_unconfirmed reg then begin
                  was_unconfirmed := true;
                  promo_alias := reg.alias
                end;
                { reg with confirmed_at = Some (Unix.gettimeofday ()) }
              end else
                reg)
            regs
        in
        if !changed then save_registrations t regs');
    if !was_unconfirmed then begin
      let alias = !promo_alias in
      let social_rooms =
        let auto_rooms =
          match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
          | Some v ->
              String.split_on_char ',' v
              |> List.map String.trim
              |> List.filter (fun s -> s <> "" && valid_room_id s)
          | None -> []
        in
        let social_room = C2c_swarm_config.swarm_config_social_room () in
        if social_room = "" then auto_rooms
        else List.sort_uniq String.compare (social_room :: auto_rooms)
      in
      let peer_reg_content =
        Printf.sprintf
          "%s registered {\"type\":\"peer_register\",\"alias\":\"%s\"}"
          alias alias
      in
      List.iter
        (fun room_id ->
          try ignore (send_room t ~from_alias:room_system_alias ~room_id ~content:peer_reg_content)
          with _ -> ())
        social_rooms;
      let joined = my_rooms t ~session_id in
      List.iter
        (fun ri ->
          try broadcast_room_join t ~room_id:ri.ri_room_id ~alias
          with _ -> ())
        joined
    end

  let touch_session t ~session_id =
    (* Self-heal stale pid before stamping last_activity_ts. If the
       reg's pid points to a dead process but a live process claims
       the same session_id, swap in the live pid + pid_start_time so
       liveness checks downstream return Alive. Errors swallowed —
       this is best-effort and must never block the touch. *)
    (try ignore (refresh_pid_if_dead t ~session_id) with _ -> ());
    (* In Docker mode, touch the lease file so cross-container peers can
       see this session is alive via the shared broker volume. *)
    (try touch_lease t ~session_id with _ -> ());
    let now = Unix.gettimeofday () in
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let changed = ref false in
      let regs' =
        List.map
          (fun reg ->
            if reg.session_id = session_id then begin
              match reg.last_activity_ts with
              | Some ts when ts >= now -> reg
              | _ ->
                changed := true;
                { reg with last_activity_ts = Some now }
            end else reg)
          regs
      in
      if !changed then save_registrations t regs')

  (* Set the [automated_delivery] flag for a session's registration.
     Called from the MCP server's initialize handler after capability
     negotiation. No-op if the session is not registered (the flip will
     happen on the next register call). *)
  let set_automated_delivery t ~session_id ~automated_delivery =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let changed = ref false in
      let regs' =
        List.map
          (fun reg ->
            if reg.session_id = session_id then begin
              match reg.automated_delivery with
              | Some b when b = automated_delivery -> reg
              | _ ->
                changed := true;
                { reg with automated_delivery = Some automated_delivery }
            end else reg)
          regs
      in
      if !changed then save_registrations t regs')

  (* #511: ordered fallback authorizers.  Resolution order: live (PID confirmed
     alive per [registration_liveness_state]) → not-DnD → not-idle
     (last_activity within 25-minute threshold matching relay_nudge idle).
     Returns the first alias in [authorizers] that satisfies all three
     predicates, or None if the list is empty or no candidate qualifies.
     The idle threshold (25 min) is hardcoded to match relay_nudge's
     default_idle_minutes; callers who want a different threshold should
     pass it explicitly (future extension). *)
  (* ---------- B140: deliberate atomic alias rename-everywhere ----------

     The sanctioned counterpart to the B135 sticky-alias forbid: an explicit
     [rename_alias] updates every alias-keyed identity store so the new name
     sticks without a session restart, with rollback on partial failure.
     Stores touched (see .collab/design/2026-07-13-b140-atomic-alias-rename.md):
       1. relay key files  keys/<alias>.ed25519{,.ssh,.ssh.pub} + x25519
       2. TOFU pins        relay_pins.json (ed25519/x25519/min-version)
       3. registry row     alias + canonical_alias, under registry lock
       4. room memberships rename_room_member_alias per joined room
     plus best-effort (post-commit, warnings only): allowed_signers entry,
     archive alias_renamed marker, peer_renamed room notices, broker.log
     event, managed instance-config sync, schedules/memory dir moves.
     Inboxes and archives are session_id-keyed, so they follow for free.

     Atomicity model: perfect multi-file atomicity is impossible (three lock
     domains), so every mutating step pushes an undo thunk and a failure
     unwinds them in reverse.  A failed undo is surfaced as an explicit
     incomplete-rollback error, never reported as "rolled back".  The
     reversible transaction orders locks alias-identity → registry →
     pending/pins/room; post-commit notifications run after release. *)

  let rename_undo_stack_note = "rolled back"

  (* Parity with C2c_start.sync_instance_alias (#159 Slice C), reimplemented
     here because c2c_start depends on this module (dependency cycle).
     Patches the "alias" field of any managed instance config whose
     session_id matches, so a restart re-launches under the new name instead
     of tripping the sticky-alias guard with the stale one. *)
  let rename_sync_instance_configs ~session_id ~new_alias : string list =
    let instances_dir =
      match Sys.getenv_opt "C2C_INSTANCES_DIR" with
      | Some d when String.trim d <> "" -> String.trim d
      | _ ->
          let home = try Sys.getenv "HOME" with Not_found -> "/" in
          List.fold_left Filename.concat home
            [ ".local"; "share"; "c2c"; "instances" ]
    in
    let warnings = ref [] in
    let entries = try Array.to_list (Sys.readdir instances_dir) with _ -> [] in
    List.iter
      (fun name ->
        let cfg_path =
          Filename.concat (Filename.concat instances_dir name) "config.json"
        in
        try
          if Sys.file_exists cfg_path then
            match Yojson.Safe.from_file cfg_path with
            | `Assoc fields ->
                let sid =
                  match List.assoc_opt "session_id" fields with
                  | Some (`String s) -> s
                  | _ -> ""
                in
                let cur_alias =
                  match List.assoc_opt "alias" fields with
                  | Some (`String s) -> s
                  | _ -> ""
                in
                if sid = session_id && cur_alias <> new_alias then begin
                  let fields' =
                    List.map
                      (fun (k, v) ->
                        if k = "alias" then (k, `String new_alias) else (k, v))
                      fields
                  in
                  write_json_file cfg_path (`Assoc fields')
                end
            | _ -> ()
        with e ->
          warnings :=
            Printf.sprintf "instance config sync failed for %s: %s" name
              (Printexc.to_string e)
            :: !warnings)
      entries;
    !warnings

  let rename_alias t ~session_id ~new_alias : (Yojson.Safe.t, string) result =
    let new_alias = String.trim new_alias in
    match
      List.find_opt (fun r -> r.session_id = session_id) (list_registrations t)
    with
    | None ->
        Error
          (Printf.sprintf
             "rename rejected: session '%s' has no registration — register \
              first, then rename"
             session_id)
    | Some old_reg ->
        let old_alias = old_reg.alias in
        if String.equal old_alias new_alias then
          Ok
            (`Assoc
              [ ("ok", `Bool true)
              ; ("old_alias", `String old_alias)
              ; ("new_alias", `String new_alias)
              ; ("noop", `Bool true)
              ])
        else if is_reserved_system_alias new_alias then
          Error
            (Printf.sprintf
               "rename rejected: '%s' is a reserved system alias" new_alias)
        else if is_banned_alias new_alias then
          Error (C2c_blocklist.blocked_alias_error new_alias)
        else if not (C2c_name.is_valid new_alias) then
          Error
            (Printf.sprintf "rename rejected: %s"
               (C2c_name.error_message "alias" new_alias))
        else begin
          (* Case-only rename ("lyra-quill" → "Lyra-Quill") is a self-rename
             only for this session.  A corrupted/contended registry can still
             contain another live session with the same case-folded alias; that
             holder must win exactly as it would for a spelling change. *)
          let case_only = alias_casefold old_alias = alias_casefold new_alias in
          let alive_holder regs =
            let target = alias_casefold new_alias in
            List.find_opt
              (fun reg ->
                alias_casefold reg.alias = target
                && reg.session_id <> session_id
                && Option.is_some reg.pid
                && registration_is_alive reg)
              regs
          in
          let holder_error regs conflict =
            let suggestion =
              (* We already hold the registry lock at the authoritative
                 validation point.  Calling the public suggestion wrapper
                 here would attempt to lock the same registry again. *)
              match suggest_alias_prime regs ~base_alias:new_alias with
              | Some s -> Printf.sprintf " Suggested free alias: '%s'." s
              | None -> ""
            in
            Printf.sprintf
              "rename rejected: alias '%s' is currently held by an alive \
               session '%s'.%s"
              new_alias conflict.session_id suggestion
          in
          let finish_success ~keys_moved ~pins_moved ~rooms =
            (* Committed. Everything below is best-effort: never roll back a
               completed rename over a cosmetic follow-up failure.  This runs
               after the registry and alias-identity locks are released; room
               notification itself resolves the registry. *)
            let warnings = ref [] in
            let warn fmt =
              Printf.ksprintf (fun s -> warnings := s :: !warnings) fmt
            in
            (match write_allowed_signers_entry t ~alias:new_alias with
             | Ok () -> ()
             | Error e -> warn "allowed_signers: %s" e
             | exception e -> warn "allowed_signers: %s" (Printexc.to_string e));
            (let marker_content =
               Yojson.Safe.to_string
                 (`Assoc
                   [ ("type", `String "alias_renamed")
                   ; ("old_alias", `String old_alias)
                   ; ("new_alias", `String new_alias)
                   ])
             in
             try
               append_archive ~drained_by:"rename" t ~session_id
                 ~messages:
                   [ { from_alias = room_system_alias
                     ; to_alias = new_alias
                     ; content = marker_content
                     ; deferrable = false
                     ; reply_via = None
                     ; enc_status = None
                     ; ts = Unix.gettimeofday ()
                     ; ephemeral = false
                     ; message_id = None
                     ; pow_difficulty = None
                     }
                   ]
             with e -> warn "archive marker: %s" (Printexc.to_string e));
            let notice =
              Printf.sprintf
                "%s renamed to %s {\"type\":\"peer_renamed\",\"old_alias\":\"%s\",\"new_alias\":\"%s\"}"
                old_alias new_alias old_alias new_alias
            in
            List.iter
              (fun ri ->
                try
                  ignore
                    (send_room t ~from_alias:room_system_alias
                       ~room_id:ri.ri_room_id ~content:notice)
                with e -> warn "room notice %s: %s" ri.ri_room_id
                  (Printexc.to_string e))
              rooms;
            (try
               log_broker_event ~broker_root:(root t) "alias_renamed"
                 [ ("ts", `Float (Unix.gettimeofday ()))
                 ; ("event", `String "alias_renamed")
                 ; ("session_id", `String session_id)
                 ; ("old_alias", `String old_alias)
                 ; ("new_alias", `String new_alias)
                 ]
             with _ -> ());
            List.iter (fun w -> warn "%s" w)
              (rename_sync_instance_configs ~session_id ~new_alias);
            let move_dir what src dst =
              try
                if Sys.file_exists src && Sys.is_directory src then
                  if Sys.file_exists dst then
                    warn "%s: target dir %s already exists — left %s in place"
                      what dst src
                  else Unix.rename src dst
              with e -> warn "%s: %s" what (Printexc.to_string e)
            in
            move_dir "schedules" (schedule_base_dir old_alias)
              (schedule_base_dir new_alias);
            move_dir "memory" (memory_base_dir old_alias)
              (memory_base_dir new_alias);
            Ok
              (`Assoc
                [ ("ok", `Bool true)
                ; ("old_alias", `String old_alias)
                ; ("new_alias", `String new_alias)
                ; ("rooms_renamed"
                  , `List (List.map (fun ri -> `String ri.ri_room_id) rooms) )
                ; ("keys_moved", `Int keys_moved)
                ; ("pins_moved", `Bool pins_moved)
                ; ("warnings"
                  , `List
                      (List.map (fun w -> `String w) (List.rev !warnings)) )
                ])
          in
          let transaction =
            with_alias_identity_locks t ~aliases:[ old_alias; new_alias ]
              (fun () ->
                with_registry_lock t (fun () ->
                  let initial_regs = load_registrations t in
                  match List.find_opt (fun r -> r.session_id = session_id) initial_regs with
                  | None -> Error "session registration disappeared during rename"
                  | Some cur when cur.alias <> old_alias ->
                      Error
                        (Printf.sprintf
                           "registration changed concurrently (alias is now '%s')"
                           cur.alias)
                  | Some _ ->
                      match alive_holder initial_regs with
                      | Some conflict -> Error (holder_error initial_regs conflict)
                      | None when
                          (not case_only)
                          && pending_permission_exists_for_alias t new_alias ->
                          Error
                            (Printf.sprintf
                               "rename rejected: alias '%s' has pending permission \
                                state from a prior owner — wait for it to resolve or \
                                time out"
                               new_alias)
                      | None -> begin
                let undos : (unit -> unit) list ref = ref [] in
                let push_undo f = undos := f :: !undos in
                let rollback () =
                  List.fold_left
                    (fun failures undo ->
                      try
                        undo ();
                        failures
                      with e -> Printexc.to_string e :: failures)
                    [] !undos
                in
                let fail stage msg =
                  match rollback () with
                  | [] ->
                      Error
                        (Printf.sprintf
                           "rename %s -> %s failed at %s: %s (%s)"
                           old_alias new_alias stage msg rename_undo_stack_note)
                  | rollback_errors ->
                      Error
                        (Printf.sprintf
                           "rename %s -> %s failed at %s: %s (rollback incomplete: %s)"
                           old_alias new_alias stage msg
                           (String.concat "; " (List.rev rollback_errors)))
                in
                (* Step 1: key material files. Alias-keyed on disk; move so
                   the identity (and its relay signatures) follows the name.
                   Refuse if the target alias already has DIFFERENT key
                   material — never overwrite another identity's keys. *)
                let move_key_files () =
                  let keys_dir = Filename.concat t.root "keys" in
                  let pairs =
                    List.map
                      (fun sfx ->
                        ( Filename.concat keys_dir (old_alias ^ sfx)
                        , Filename.concat keys_dir (new_alias ^ sfx) ))
                      [ ".ed25519"; ".ed25519.ssh"; ".ed25519.ssh.pub" ]
                    @ [ ( Relay_enc.default_path ~alias:old_alias
                        , Relay_enc.default_path ~alias:new_alias )
                      ]
                  in
                  let moved = ref 0 in
                  let rec go = function
                    | [] -> Ok !moved
                    | (src, dst) :: rest ->
                        let src_exists = Sys.file_exists src in
                        let dst_exists = Sys.file_exists dst in
                        if not src_exists then
                          if dst_exists then
                            (* We cannot establish that a target-only raw key
                               belongs to this old alias.  Treat it as stale
                               rather than silently declaring a successful
                               rename that leaves alias-keyed material behind. *)
                            Error
                              (Printf.sprintf
                                 "alias '%s' has target-only key material at %s \
                                  while source %s is missing — refusing stale key"
                                 new_alias dst src)
                          else go rest
                        else
                          let source = C2c_io.read_file src in
                          let source_mode = (Unix.stat src).Unix.st_perm in
                          let restore_source () =
                            if Sys.file_exists src then
                              failwith
                                (Printf.sprintf
                                   "rollback refused to overwrite changed source key %s"
                                   src)
                            else
                              match C2c_io.write_file_atomic src source with
                              | Error e ->
                                  failwith
                                    (Printf.sprintf
                                       "could not restore source key %s: %s"
                                       src e)
                              | Ok () -> Unix.chmod src source_mode
                          in
                          if dst_exists then
                            if source = C2c_io.read_file dst then begin
                              (* Identical pre-existing target material still
                                 requires removal of the old raw key.  Undo
                                 recreates only our source and never deletes a
                                 target that has changed since this step. *)
                              (match Unix.unlink src with
                               | () ->
                                   push_undo (fun () ->
                                       restore_source ());
                                   incr moved;
                                   go rest
                               | exception e -> Error (Printexc.to_string e))
                            end else
                              Error
                                (Printf.sprintf
                                   "alias '%s' already has different key \
                                    material at %s — refusing to overwrite"
                                   new_alias dst)
                          else
                            (match Unix.rename src dst with
                             | () ->
                                 push_undo (fun () ->
                                     if Sys.file_exists src then
                                       failwith
                                         (Printf.sprintf
                                            "rollback refused to overwrite changed source key %s"
                                            src)
                                     else if
                                       Sys.file_exists dst
                                       && C2c_io.read_file dst = source
                                     then Unix.rename dst src
                                     else restore_source ());
                                 incr moved;
                                 go rest
                             | exception e -> Error (Printexc.to_string e))
                  in
                  go pairs
                in
                (* Step 2: TOFU pins. Move old-alias pins to the new alias so
                   peers' trust continuity follows the rename. Fail closed if
                   the target alias carries pins from a previous holder. *)
                let move_pins () =
                  with_relay_pins_lock (fun () ->
                      load_relay_pins_from_disk ();
                      let old_ed =
                        Hashtbl.find_opt known_keys_ed25519 old_alias
                      in
                      let old_x =
                        Hashtbl.find_opt known_keys_x25519 old_alias
                      in
                      let new_ed =
                        Hashtbl.find_opt known_keys_ed25519 new_alias
                      in
                      let new_x =
                        Hashtbl.find_opt known_keys_x25519 new_alias
                      in
                      let conflict kind old_pk new_pk =
                        match (old_pk, new_pk) with
                        | Some o, Some n when o <> n -> Some kind
                        | None, Some _ -> Some kind
                        | _ -> None
                      in
                      match
                        ( conflict "ed25519" old_ed new_ed
                        , conflict "x25519" old_x new_x )
                      with
                      | Some kind, _ | None, Some kind ->
                          Error
                            (Printf.sprintf
                               "alias '%s' already has pinned %s key material \
                                from a previous holder — choose a different \
                                alias or clear the stale pin (c2c relay-pins)"
                               new_alias kind)
                      | None, None ->
                          let old_min =
                            Hashtbl.find_opt min_observed_envelope_versions
                              old_alias
                          in
                          let new_min =
                            Hashtbl.find_opt min_observed_envelope_versions
                              new_alias
                          in
                          let restore_snapshot () =
                            let restore tbl alias prior =
                              match prior with
                              | Some v -> Hashtbl.replace tbl alias v
                              | None -> Hashtbl.remove tbl alias
                            in
                            restore known_keys_ed25519 old_alias old_ed;
                            restore known_keys_ed25519 new_alias new_ed;
                            restore known_keys_x25519 old_alias old_x;
                            restore known_keys_x25519 new_alias new_x;
                            restore min_observed_envelope_versions old_alias
                              old_min;
                            restore min_observed_envelope_versions new_alias
                              new_min
                          in
                          let moved = ref false in
                          (match old_ed with
                          | Some pk ->
                              Hashtbl.replace known_keys_ed25519 new_alias pk;
                              Hashtbl.remove known_keys_ed25519 old_alias;
                              moved := true
                          | None -> ());
                          (match old_x with
                          | Some pk ->
                              Hashtbl.replace known_keys_x25519 new_alias pk;
                              Hashtbl.remove known_keys_x25519 old_alias;
                              moved := true
                          | None -> ());
                          (match old_min with
                          | Some v ->
                              let merged =
                                match new_min with
                                | Some nv when nv > v -> nv
                                | _ -> v
                              in
                              Hashtbl.replace min_observed_envelope_versions
                                new_alias merged;
                              Hashtbl.remove min_observed_envelope_versions
                                old_alias;
                              moved := true
                          | None -> ());
                          if !moved then
                            (try
                               save_relay_pins_to_disk ();
                               push_undo (fun () ->
                                   with_relay_pins_lock (fun () ->
                                       load_relay_pins_from_disk ();
                                       restore_snapshot ();
                                       save_relay_pins_to_disk ()))
                             with e ->
                               (* [save_relay_pins_to_disk] is normally an
                                  atomic temp+rename.  Nevertheless restore
                                  the in-memory snapshot and best-effort
                                  persist it before propagating an error, so a
                                  failed save cannot leak a half-moved pin. *)
                               restore_snapshot ();
                               (try save_relay_pins_to_disk () with _ -> ());
                               raise e);
                          Ok !moved)
                in
                (* Step 3: the registry row — the commit point peers observe
                   via list/whoami. Guards are revalidated under the registry
                   lock (the pre-checks above are TOCTOU-racy by nature).
                   The surrounding transaction already owns that lock. *)
                let update_registry () =
                  let regs = load_registrations t in
                  match List.find_opt (fun r -> r.session_id = session_id) regs with
                  | None -> Error "session registration disappeared during rename"
                  | Some cur when cur.alias <> old_alias ->
                      Error
                        (Printf.sprintf
                           "registration changed concurrently (alias is now '%s')"
                           cur.alias)
                  | Some _ ->
                      match alive_holder regs with
                      | Some conflict -> Error (holder_error regs conflict)
                      | None ->
                          (* Registry → pending is the only multi-store order:
                             opening a pending permission never takes the
                             registry lock.  Keep the pending lock across the
                             following registry write, so this is the actual
                             linearization point rather than a TOCTOU check. *)
                          with_pending_lock t (fun () ->
                              if
                                (not case_only)
                                && pending_permission_exists_for_alias_unlocked
                                     t new_alias
                              then
                                Error
                                  (Printf.sprintf
                                     "rename rejected: alias '%s' has pending permission \
                                      state from a prior owner — wait for it to resolve or \
                                      time out"
                                     new_alias)
                              else
                                let regs' =
                                  List.map
                                    (fun r ->
                                      if r.session_id = session_id then
                                        { r with
                                          alias = new_alias
                                        ; canonical_alias =
                                            Some
                                              (compute_canonical_alias
                                                 ~deprecate_canonical_alias:
                                                   t.deprecate_canonical_alias
                                                 ~alias:new_alias
                                                 ~broker_root:(root t) ())
                                        }
                                      else r)
                                    regs
                                in
                                save_registrations t regs';
                                push_undo (fun () ->
                                    let regs = load_registrations t in
                                    let regs' =
                                      List.map
                                        (fun r ->
                                          if r.session_id = session_id then
                                            { r with
                                              alias = old_alias
                                            ; canonical_alias = old_reg.canonical_alias
                                            }
                                          else r)
                                        regs
                                    in
                                    save_registrations t regs');
                                Ok ())
                in
                (* Step 4: room memberships (per-room lock, keyed by
                   session_id, so this is order-independent of step 3). *)
                let rooms = my_rooms t ~session_id in
                let rename_rooms () =
                  try
                    List.iter
                      (fun ri ->
                        let room_id = ri.ri_room_id in
                        ignore
                          (rename_room_member_alias t ~room_id ~session_id
                             ~new_alias);
                        push_undo (fun () ->
                            ignore
                              (rename_room_member_alias t ~room_id ~session_id
                                 ~new_alias:old_alias)))
                      rooms;
                    Ok ()
                  with e -> Error (Printexc.to_string e)
                in
                match move_key_files () with
                | Error e -> fail "key-files" e
                | exception e -> fail "key-files" (Printexc.to_string e)
                | Ok keys_moved -> (
                    match move_pins () with
                    | Error e -> fail "pins" e
                    | exception e -> fail "pins" (Printexc.to_string e)
                    | Ok pins_moved -> (
                        match update_registry () with
                        | Error e -> fail "registry" e
                        | exception e -> fail "registry" (Printexc.to_string e)
                        | Ok () -> (
                            match rename_rooms () with
                            | Error e -> fail "rooms" e
                            | exception e -> fail "rooms" (Printexc.to_string e)
                            | Ok () -> Ok (keys_moved, pins_moved, rooms))))
                      end))
          in
          match transaction with
          | Error e -> Error e
          | Ok (keys_moved, pins_moved, rooms) ->
              finish_success ~keys_moved ~pins_moved ~rooms
        end

  let resolve_authorizers t ~(authorizers : string list) : string option =
    if authorizers = [] then None
    else
      let now = Unix.gettimeofday () in
      let idle_threshold_s = 25.0 *. 60.0 in
      let regs = list_registrations t in
      let rec find_first = function
        | [] -> None
        | alias :: rest ->
            (match List.find_opt (fun r -> r.alias = alias) regs with
             | None -> find_first rest
             | Some reg ->
                 if registration_liveness_state reg <> Alive then find_first rest
                 else if is_dnd t ~session_id:reg.session_id then find_first rest
                 else
                   (match reg.last_activity_ts with
                    | None -> find_first rest
                    | Some ts ->
                        if now -. ts > idle_threshold_s then find_first rest
                        else Some alias))
      in
      find_first authorizers
