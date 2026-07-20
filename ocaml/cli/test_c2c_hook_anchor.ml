(* test_c2c_hook_anchor — #51: does firing a hook actually advance the
   activity anchor the liveness TTL is measured against?

   The #51 fix declares a pid-less hook registration Dead once its
   [last_activity_ts] is older than the hook TTL. That is only safe if the
   client's INSTALLED hooks fire MID-SESSION and reach
   [touch_hook_activity]; otherwise the anchor never advances past
   SessionStart and the TTL silently measures session AGE, killing live
   agents' delivery.

   The original #51 test suite was pure-function checks over hand-built
   records with a pre-seeded [last_activity_ts]. Nothing asserted that a real
   hook fire moves the anchor, so a client whose events never reach the touch
   (grok / claude / kimi, all SessionStart+SessionEnd only) passed 3019 green
   tests while being decay-eligible. This file closes that hole.

   The invariant under test, one line:

     a hook client decays  <=>  it has a PROVEN mid-session anchor

   Both directions are asserted, so the suite fails loudly in either
   direction of drift:

   - forward: a client we DO decay must advance its anchor when its
     mid-session hook fires. Firing is end-to-end through the real `c2c`
     binary, so an event that hard-exits before the touch fails here.
   - reverse: a client we do NOT decay must still be offered by `c2c list`
     however old its row is. Adding a client to the decay allowlist without
     first giving it a mid-session anchor therefore fails this file rather
     than shipping.

   Plus a #51 blocker-2 guard: a MANAGED session's row must never be labelled
   "<client>-hook", because that label is what subjects a row to the TTL. *)

open Alcotest

let ( // ) = Filename.concat

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun child -> remove_tree (path // child)) (Sys.readdir path);
    Unix.rmdir path
  end
  else Sys.remove path

let mkdir_p path =
  let rec loop p =
    if Sys.file_exists p then ()
    else begin
      loop (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  if path <> "" && path <> Filename.dirname path then loop path

let read_file path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else
    let rec at i =
      i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1))
    in
    at 0

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

type ctx = { dir : string; home : string; broker_root : string }

let with_ctx f =
  let dir =
    Filename.get_temp_dir_name ()
    // Printf.sprintf "c2c-hook-anchor-%08x" (Random.bits ())
  in
  let home = dir // "home" and broker_root = dir // "broker" in
  mkdir_p home;
  mkdir_p broker_root;
  Fun.protect
    ~finally:(fun () -> try remove_tree dir with _ -> ())
    (fun () -> f { dir; home; broker_root })

(* Seed one pid-less hook registration whose anchor sits [age_s] in the past.
   Written as raw registry JSON rather than via [Broker.register] so the
   backdated anchor is exactly what the hook has to move. *)
let seed_hook_row ctx ~session_id ~alias ~registered_by ~client_type ~age_s =
  let ts = Unix.gettimeofday () -. age_s in
  let row =
    `Assoc
      [ ("session_id", `String session_id)
      ; ("alias", `String alias)
      ; ("registered_at", `Float ts)
      ; ("last_activity_ts", `Float ts)
      ; ("client_type", `String client_type)
      ; ("registered_by", `String registered_by)
      ]
  in
  write_file (ctx.broker_root // "registry.json")
    (Yojson.Safe.to_string (`List [ row ]));
  ts

let read_anchor ctx ~session_id =
  match Yojson.Safe.from_file (ctx.broker_root // "registry.json") with
  | `List rows ->
      List.find_map
        (fun row ->
          match row with
          | `Assoc fields
            when List.assoc_opt "session_id" fields = Some (`String session_id)
            -> (
              match List.assoc_opt "last_activity_ts" fields with
              | Some (`Float f) -> Some f
              | Some (`Int i) -> Some (float_of_int i)
              | _ -> None)
          | _ -> None)
        rows
  | _ -> None

(* Fire the real binary with a scrubbed environment: `env -i` keeps ambient
   C2C_MCP_SESSION_ID / managed markers out, so the hook resolves as vanilla
   exactly as it would in a user's session. *)
let fire ?(extra_env = []) ctx ~args ~payload =
  let payload_path = ctx.dir // "payload.json" in
  write_file payload_path payload;
  let extra =
    String.concat " "
      (List.map
         (fun (k, v) -> Printf.sprintf "%s=%s" k (Filename.quote v))
         extra_env)
  in
  let cmd =
    Printf.sprintf
      "env -i HOME=%s PATH=%s C2C_MCP_BROKER_ROOT=%s %s %s %s < %s > %s 2> %s"
      (Filename.quote ctx.home)
      (Filename.quote (Sys.getenv "PATH"))
      (Filename.quote ctx.broker_root)
      extra
      (Filename.quote c2c_binary)
      args
      (Filename.quote payload_path)
      (Filename.quote (ctx.dir // "hook.out"))
      (Filename.quote (ctx.dir // "hook.err"))
  in
  ignore (Sys.command cmd)

(* The decay contract, as data.

   [mid_session] lists every ([args], [payload_extra]) invocation of an
   INSTALLED hook event that fires repeatedly during a session AND must reach
   the touch. It is EMPTY for a client installed with SessionStart /
   SessionEnd only, whose anchor can therefore never advance past session
   start.

   Keep this table in step with:
   - the installed hook events (`C2c_setup`: codex writes
     UserPromptSubmit+PostToolUse+SessionStart+SessionEnd; agy writes
     SessionStart+PostToolUse+Stop; claude writes PostToolUse+Stop alongside
     its SessionStart/SessionEnd hook; grok and kimi write SessionStart +
     mid-session UserPromptSubmit/PreToolUse/PostToolUse/Stop + SessionEnd
     after #59), and
   - [Broker.hook_anchor_is_activity_backed], which gates decay. *)
let clients =
  [ ( "codex-hook"
    , "codex"
    , [ ("hook codex", {|"hook_event_name":"PostToolUse",|})
      ; ("hook codex", {|"hook_event_name":"UserPromptSubmit",|})
      ] )
    (* Claude's repeatedly-firing hooks are the standalone PostToolUse / Stop
       scripts (`c2c hook post-tool` / `c2c hook stop`), NOT `c2c hook claude`
       — that command hard-exits on any event outside SessionStart/SessionEnd
       before it can touch. Asserting the wrong command here would have been
       green while the real delivery path stayed unanchored. *)
  ; ("claude-hook", "claude", [ ("hook post-tool", ""); ("hook stop", "") ])
    (* Both of agy's mid-session events anchor. Stop used to be excluded here
       because it shared the SessionEnd teardown arm and DEREGISTERED the row
       (#61) — that was the bug, not the contract: agy installs Stop as an
       ordinary turn-end hook, so it is the most frequent anchor agy has. *)
  ; ("agy-hook", "agy", [ ("hook agy PostToolUse", ""); ("hook agy Stop", "") ])
  ; ( "grok-hook"
    , "grok"
    , [ ("hook grok", {|"hook_event_name":"PostToolUse",|})
      ; ("hook grok", {|"hook_event_name":"UserPromptSubmit",|})
      ; ("hook grok", {|"hook_event_name":"Stop",|})
      ] )
  ; ( "kimi-hook"
    , "kimi"
    , [ ("hook kimi", {|"hook_event_name":"PostToolUse",|})
      ; ("hook kimi", {|"hook_event_name":"UserPromptSubmit",|})
      ; ("hook kimi", {|"hook_event_name":"Stop",|})
      ] )
  ]

(* Forward direction: a mid-session hook fire must move the anchor. *)
let test_mid_session_hook_advances_anchor () =
  List.iter
    (fun (registered_by, client_type, mid_session) ->
      List.iter
        (fun (args, payload_extra) ->
          with_ctx (fun ctx ->
              let session_id = Printf.sprintf "anchor-%s-sid" client_type in
              let alias = Printf.sprintf "anchor-%s-peer" client_type in
              let before =
                seed_hook_row ctx ~session_id ~alias ~registered_by ~client_type
                  ~age_s:3600.0
              in
              let payload =
                Printf.sprintf {|{%s"session_id":"%s","cwd":"%s"}|} payload_extra
                  session_id ctx.dir
              in
              fire ctx ~args ~payload;
              match read_anchor ctx ~session_id with
              | None ->
                  failf
                    "%s: registration vanished after firing `c2c %s` — the row \
                     under test must survive the hook"
                    registered_by args
              | Some after ->
                  check bool
                    (Printf.sprintf
                       "%s: firing `c2c %s` must advance last_activity_ts \
                        (before=%.3f after=%.3f). If this fails, the TTL is \
                        measuring session AGE, not activity, and live %s \
                        sessions will be declared Dead."
                       registered_by args before after client_type)
                    true
                    (after > before +. 60.0)))
        mid_session)
    clients

(* Reverse direction: no proven mid-session anchor => no decay, ever.

   Asserted on the user-visible surface rather than a predicate, because that
   is where the harm lands: a decayed row reads [Dead], `list` hides it, and
   [resolve_alias] answers [Unknown_alias] — at which point [send_all] skips
   the peer with no `skipped` entry and a 1:1 DM raises before it can reach
   the B127 offline queue, destroying the message rather than parking it. *)
let test_decay_only_for_activity_backed_clients () =
  List.iter
    (fun (registered_by, client_type, mid_session) ->
      let has_anchor = mid_session <> [] in
      with_ctx (fun ctx ->
          let session_id = Printf.sprintf "decay-%s-sid" client_type in
          let alias = Printf.sprintf "decay%speer" client_type in
          ignore
            (seed_hook_row ctx ~session_id ~alias ~registered_by ~client_type
               ~age_s:(30.0 *. 24.0 *. 3600.0));
          fire ctx ~args:"list" ~payload:"{}";
          let listing = read_file (ctx.dir // "hook.out") in
          let visible = contains ~haystack:listing ~needle:alias in
          check bool
            (Printf.sprintf
               "%s: a 30-day-old pid-less row may only disappear from `c2c \
                list` when the client has a proven mid-session anchor \
                (has_anchor=%b). Listing was:\n%s"
               registered_by has_anchor listing)
            (not has_anchor) visible))
    clients

(* #51 blocker 2: managed agy now eager-registers pre-fork, but the hook may
   still write/adopt a row when markers are present. Labelling a managed row
   "agy-hook" made it pid-less AND decaying: idle past the TTL — precisely when
   its out-of-process agentapi wake still works — it flipped Dead and sends
   were refused. The same label is the SessionEnd deregister selector, so an
   ordinary teardown path also tore the managed row down. Grok is the same
   latent shape (managed grok is deferred, so this is pre-emptive there). *)
let test_managed_session_row_is_not_labelled_hook () =
  List.iter
    (fun (client, args, marker) ->
      with_ctx (fun ctx ->
          let sid = Printf.sprintf "managed-%s-sid" client in
          fire ctx ~args
            ~extra_env:[ (marker, sid) ]
            ~payload:
              (Printf.sprintf {|{"session_id":"%s","cwd":"%s"}|} sid ctx.dir);
          let registry = read_file (ctx.broker_root // "registry.json") in
          check bool
            (Printf.sprintf
               "%s: a managed session's row must not carry the \"%s-hook\"                 label (registry was: %s)"
               client client registry)
            false
            (contains ~haystack:registry ~needle:(client ^ "-hook"))))
    [ ("agy", "hook agy SessionStart", "C2C_MCP_SESSION_ID")
    ; ("agy", "hook agy SessionStart", "C2C_MCP_AUTO_REGISTER_ALIAS")
    ; ("grok", "hook grok", "C2C_MCP_SESSION_ID")
    ]

let () =
  run "c2c-hook-anchor"
    [ ( "#51 activity anchor"
      , [ test_case "mid-session hook fire advances last_activity_ts" `Quick
            test_mid_session_hook_advances_anchor
        ; test_case "decay is gated to clients with a mid-session anchor" `Quick
            test_decay_only_for_activity_backed_clients
        ; test_case "managed session rows are never labelled <client>-hook"
            `Quick test_managed_session_row_is_not_labelled_hook
        ] )
    ]
