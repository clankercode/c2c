(* Host-owned mailboxes. The registry lock fences the binding and registration
   together; inbox operations nest only the existing inbox lock beneath it.
   No provider process, approval path, or native delivery loop is involved. *)
module B = C2c_broker
open C2c_mcp_helpers

type binding = {
  environment_id : string;
  thread_id : string;
  session_id : string;
  alias : string;
  workspace : string;
  broker_root : string;
  inbox_path : string;
  generation : string;
  owner_pid : int;
  owner_pid_start_time : int;
}

type stored = { binding : binding; owner_id : string; active : bool }
exception Rejected of string
let reject reason = raise (Rejected reason)

let require_text name value =
  if String.trim value = "" || String.length value > 4096
     || String.contains value '\000' then reject ("invalid_" ^ name)

let identity ~environment_id ~thread_id =
  require_text "environment_id" environment_id;
  require_text "thread_id" thread_id;
  (* Length framing prevents ambiguous concatenations of external IDs. *)
  let frame s = string_of_int (String.length s) ^ ":" ^ s in
  let digest = Digestif.SHA256.(to_hex (digest_string
    ("c2c-host-mailbox-v1\000" ^ frame environment_id ^ frame thread_id))) in
  "host-" ^ digest, digest

let binding_to_json b = `Assoc [
  "environment_id", `String b.environment_id; "thread_id", `String b.thread_id;
  "session_id", `String b.session_id; "alias", `String b.alias;
  "workspace", `String b.workspace; "broker_root", `String b.broker_root;
  "inbox_path", `String b.inbox_path; "generation", `String b.generation;
  "owner_pid", `Int b.owner_pid; "owner_pid_start_time", `Int b.owner_pid_start_time ]

let response fields = `Assoc (("schema_version", `Int 1) :: fields)
let binding_response b = response ["binding", binding_to_json b]
let state_path broker session_id =
  Filename.concat (Filename.concat (B.root broker) "host-bindings") (session_id ^ ".json")
let marker b = "host-mailbox:" ^ b.generation

let stored_to_json state = response ["binding", binding_to_json state.binding;
  "owner_id", `String state.owner_id; "active", `Bool state.active]

let stored_of_json broker ~environment_id ~thread_id json =
  let session_id, _ = identity ~environment_id ~thread_id in
  let open Yojson.Safe.Util in
  if json |> member "schema_version" |> to_int <> 1 then reject "invalid_binding";
  let b = json |> member "binding" in
  let text key = b |> member key |> to_string in
  let binding = { environment_id = text "environment_id"; thread_id = text "thread_id";
    session_id = text "session_id"; alias = text "alias"; workspace = text "workspace";
    broker_root = text "broker_root"; inbox_path = text "inbox_path";
    generation = text "generation"; owner_pid = b |> member "owner_pid" |> to_int;
    owner_pid_start_time = b |> member "owner_pid_start_time" |> to_int } in
  if binding.environment_id <> environment_id || binding.thread_id <> thread_id
     || binding.session_id <> session_id || binding.broker_root <> B.root broker
     || binding.inbox_path <> B.inbox_path broker ~session_id
     || not (C2c_name.is_valid binding.alias) || binding.generation = ""
     || binding.owner_pid <= 0
  then reject "invalid_binding";
  let owner_id = json |> member "owner_id" |> to_string in
  require_text "owner_id" owner_id;
  { binding; owner_id; active = json |> member "active" |> to_bool }

let read_state broker ~environment_id ~thread_id =
  let session_id, _ = identity ~environment_id ~thread_id in
  let file_path = state_path broker session_id in
  if not (Sys.file_exists file_path) then None else
  try Some (stored_of_json broker ~environment_id ~thread_id
    (Yojson.Safe.from_string (C2c_io.read_file file_path)))
  with Rejected _ as e -> raise e | _ -> reject "invalid_binding"

let write_durable_json path json =
  C2c_io.mkdir_p_durable (Filename.dirname path);
  B.write_json_file path json;
  C2c_io.fsync_file_and_parent path

let write_state broker state =
  write_durable_json (state_path broker state.binding.session_id) (stored_to_json state)

let registration_matches (r : registration) b =
  r.session_id = b.session_id && r.alias = b.alias
  && r.registered_by = Some (marker b) && r.cwd = Some b.workspace
  && r.client_type = Some "host" && r.pid = Some b.owner_pid
  && r.pid_start_time = Some b.owner_pid_start_time
  && r.automated_delivery = Some false

let touching_registrations (regs : registration list) b =
  List.filter (fun (r : registration) -> r.session_id = b.session_id
    || B.alias_casefold r.alias = B.alias_casefold b.alias) regs

let owned_registration regs b =
  match touching_registrations regs b with
  | [] -> None
  | [r] when registration_matches r b -> Some r
  | _ -> reject "registration_conflict"

let registration_for_binding existing binding =
  let now = Unix.gettimeofday () in
  let r = match existing with Some r -> r | None ->
    B.registration_of_json (`Assoc ["session_id", `String binding.session_id;
      "alias", `String binding.alias]) in
  { r with pid = Some binding.owner_pid; pid_start_time = Some binding.owner_pid_start_time;
    registered_at = Some now; confirmed_at = Some now; last_activity_ts = Some now;
    client_type = Some "host"; registered_by = Some (marker binding);
    cwd = Some binding.workspace; automated_delivery = Some false }

(* A write-ahead transition is the authority for the two-file publication.
   It names both exact generations before either file changes. Recovery accepts
   only their owned row (or absence), never a row merely sharing the alias/PID. *)
type transition = { before : stored option; after : stored }
let transition_path broker session_id = state_path broker session_id ^ ".pending"
let after_state_write_for_test = ref None
let set_after_state_write_for_test hook = after_state_write_for_test := hook

let read_transition broker ~environment_id ~thread_id =
  let session_id, _ = identity ~environment_id ~thread_id in
  let file_path = transition_path broker session_id in
  if not (Sys.file_exists file_path) then None else
  try
    let json = Yojson.Safe.from_string (C2c_io.read_file file_path) in
    let open Yojson.Safe.Util in
    if json |> member "schema_version" |> to_int <> 1 then reject "invalid_binding_transition";
    let parse = stored_of_json broker ~environment_id ~thread_id in
    let before = match json |> member "before" with `Null -> None | j -> Some (parse j) in
    let after = parse (json |> member "after") in
    (match before with
     | Some old when old.binding.alias <> after.binding.alias -> reject "invalid_binding_transition"
     | _ -> ());
    Some { before; after }
  with Rejected _ as e -> raise e | _ -> reject "invalid_binding_transition"

let finish_transition broker transition regs =
  let target = transition.after in
  let current = match touching_registrations regs target.binding with
    | [] -> None
    | [r] when registration_matches r target.binding
        || (match transition.before with
            | Some old -> registration_matches r old.binding | None -> false) -> Some r
    | _ -> reject "registration_conflict" in
  write_state broker target;
  (match !after_state_write_for_test with None -> () | Some hook -> hook ());
  let others = List.filter (fun (r : registration) -> r.session_id <> target.binding.session_id) regs in
  let next = if target.active then
      registration_for_binding current target.binding :: others else others in
  B.save_registrations broker next;
  C2c_io.fsync_file_and_parent (B.registry_path broker);
  let journal = transition_path broker target.binding.session_id in
  Unix.unlink journal;
  C2c_io.fsync_path (Filename.dirname journal)

let recover_transition broker ~environment_id ~thread_id =
  match read_transition broker ~environment_id ~thread_id with
  | None -> ()
  | Some transition ->
      let current = read_state broker ~environment_id ~thread_id in
      if current <> transition.before && current <> Some transition.after
      then reject "binding_transition_conflict";
      finish_transition broker transition (B.load_registrations_strict broker)

let publish_transition broker ~before ~after regs =
  let path = transition_path broker after.binding.session_id in
  write_durable_json path (response [
    "before", (match before with None -> `Null | Some state -> stored_to_json state);
    "after", stored_to_json after]);
  finish_transition broker { before; after } regs

let canonical_root ?(create = false) root =
  require_text "broker_root" root;
  if create then C2c_io.mkdir_p_durable root;
  Unix.realpath root

let bind ~environment_id ~thread_id ~workspace ~owner_id ?(owner_pid = Unix.getppid ()) ?alias ?broker_root ?expected_broker_root () =
  let session_id, default_alias = identity ~environment_id ~thread_id in
  require_text "owner_id" owner_id;
  if owner_pid <= 0 then reject "invalid_owner_pid";
  let owner_pid_start_time = match B.capture_pid_start_time (Some owner_pid) with
    | Some start -> start | None -> reject "owner_not_alive" in
  require_text "workspace" workspace;
  let workspace = Unix.realpath workspace in
  if not (Sys.is_directory workspace) then reject "invalid_workspace";
  (* Resolve repo identity from the requested workspace, never the T3 server's
     cwd or a memoized fingerprint of another thread. Restore both on exit. *)
  let root = match broker_root with
    | Some root -> canonical_root ~create:true root
    | None ->
        let cwd = Sys.getcwd () in
        Fun.protect ~finally:(fun () -> Unix.chdir cwd;
          C2c_repo_fp.reset_repo_fingerprint_cache ()) (fun () ->
          Unix.chdir workspace; C2c_repo_fp.reset_repo_fingerprint_cache ();
          canonical_root ~create:true (C2c_repo_fp.resolve_broker_root ())) in
  (match expected_broker_root with
   | Some expected when canonical_root expected <> root -> reject "workspace_broker_changed"
   | _ -> ());
  let broker = B.create ~root in
  B.with_registry_lock broker (fun () ->
    recover_transition broker ~environment_id ~thread_id;
    let previous = read_state broker ~environment_id ~thread_id in
    let alias = match alias, previous with
      | Some a, _ -> a | None, Some s -> s.binding.alias | None, None -> default_alias in
    if not (C2c_name.is_valid alias) || B.is_reserved_system_alias alias
       || B.is_banned_alias alias then reject "invalid_alias";
    let regs = B.load_registrations_strict broker in
    let old_reg = match previous with
      | Some s ->
          if alias <> s.binding.alias then reject "alias_change_requires_new_identity";
          owned_registration regs s.binding
      | None ->
          if List.exists (fun (r : registration) -> r.session_id = session_id
            || B.alias_casefold r.alias = B.alias_casefold alias) regs
          then reject "registration_conflict";
          None in
    let unchanged = match previous, old_reg with
      | Some s, Some _ -> s.active && s.owner_id = owner_id && s.binding.workspace = workspace
          && s.binding.owner_pid = owner_pid
          && s.binding.owner_pid_start_time = owner_pid_start_time
      | _ -> false in
    let generation = match previous with
      | Some s when unchanged -> s.binding.generation
      | _ -> B.generate_msg_id () in
    let binding = { environment_id; thread_id; session_id; alias; workspace;
      broker_root = root; inbox_path = B.inbox_path broker ~session_id; generation;
      owner_pid; owner_pid_start_time } in
    if not unchanged then begin
      if B.capture_pid_start_time (Some owner_pid) <> Some owner_pid_start_time
      then reject "owner_not_alive";
      publish_transition broker ~before:previous ~after:{ binding; owner_id; active = true } regs
    end;
    binding_response binding)

let with_binding ~environment_id ~thread_id ~broker_root ~generation f =
  require_text "generation" generation;
  let broker = B.create ~root:(canonical_root broker_root) in
  B.with_registry_lock broker (fun () ->
    let session_id, _ = identity ~environment_id ~thread_id in
    if Sys.file_exists (transition_path broker session_id) then reject "binding_transition_pending";
    match read_state broker ~environment_id ~thread_id with
    | None -> reject "binding_not_found"
    | Some s when s.binding.generation <> generation -> reject "stale_generation"
    | Some s ->
        let regs = B.load_registrations_strict broker in
        let registration = owned_registration regs s.binding in
        f broker s regs registration)

let require_active state = function
  | Some r when state.active -> r
  | _ -> reject "binding_inactive"

let max_page_messages = 64
let max_content_bytes = 65536
let max_page_bytes = 4 * 1024 * 1024

let message_to_json m =
  (* The host DTO exposes only its contracted envelope. In particular a legacy
     reply hint cannot bypass the byte budget or grow omitted-body metadata. *)
  let fields = match B.message_to_json m with
    | `Assoc fields -> List.filter (fun (key, _) ->
        List.mem key ["message_id"; "from_alias"; "to_alias"; "content"; "ts"; "source"]) fields
    | _ -> assert false in
  let flags = ["ephemeral", `Bool m.ephemeral; "deferrable", `Bool m.deferrable] in
  let content_bytes = String.length m.content in
  if content_bytes <= max_content_bytes then `Assoc (flags @ fields)
  else `Assoc (flags @ ["content", `Null; "content_omitted_reason", `String "oversized";
      "content_bytes", `Int content_bytes] @ List.remove_assoc "content" fields)

let message_page ~limit messages =
  (* Count actual JSON bytes, including commas and array brackets, rather than
     body bytes: control characters can expand sixfold during serialization. *)
  let rec take count bytes rows = function
    | [] -> List.rev rows, false
    (* Reaching the row limit is only evidence of another page when an
       unconsumed row remains.  An exact-limit page is final. *)
    | remaining when count = limit ->
        List.rev rows, (match remaining with [] -> false | _ :: _ -> true)
    | message :: rest ->
        let row = message_to_json message in
        let row_bytes = String.length (Yojson.Safe.to_string row) in
        let next_bytes = bytes + row_bytes + (if count = 0 then 0 else 1) in
        if next_bytes > max_page_bytes then
          if count = 0 then reject "oversized_envelope"
          else List.rev rows, true
        else take (count + 1) next_bytes (row :: rows) rest in
  take 0 2 [] messages

let peek ?(limit = max_page_messages) ~environment_id ~thread_id ~broker_root ~generation () =
  if limit < 1 || limit > max_page_messages then reject "invalid_limit";
  with_binding ~environment_id ~thread_id ~broker_root ~generation
    (fun broker state _ registration ->
      let r = require_active state registration in
      let messages = B.read_inbox ~assign_ids:true ~strict:true broker
        ~session_id:state.binding.session_id in
      if Sys.file_exists state.binding.inbox_path then
        C2c_io.fsync_file_and_parent state.binding.inbox_path;
      let messages, has_more = message_page ~limit messages in
      let dnd = r.dnd && (match r.dnd_until with
        | None -> true | Some until -> Unix.gettimeofday () < until) in
      let dnd_until = if dnd then match r.dnd_until with
        | Some until -> `Float until | None -> `Null else `Null in
      response ["binding", binding_to_json state.binding; "dnd", `Bool dnd;
        "dnd_until", dnd_until; "messages", `List messages; "has_more", `Bool has_more])

let send ~environment_id ~thread_id ~broker_root ~generation ~to_alias ~content =
  require_text "recipient" to_alias;
  (* Host send is transported through an argv element. POSIX exec cannot
     represent NUL in argv, so reject it at this seam for direct callers too. *)
  if content = "" || String.length content > max_content_bytes
     || String.contains content '\000' then reject "invalid_content";
  with_binding ~environment_id ~thread_id ~broker_root ~generation
    (fun broker state _ registration ->
      ignore (require_active state registration);
      (try
        let result = B.enqueue_message_with_result_locked ~allow_pending_verdict:false broker
          ~from_alias:state.binding.alias ~to_alias ~content () in
        let path = match result with
          | B.Local_live {session_id} | B.Local_offline {session_id} -> B.inbox_path broker ~session_id
          | B.Relay_outbox -> C2c_relay_connector.outbox_path (B.root broker) in
        C2c_io.fsync_file_and_parent path
       with Invalid_argument _ -> reject "invalid_recipient");
      response ["binding", binding_to_json state.binding; "queued", `Bool true])

let ack ~environment_id ~thread_id ~broker_root ~generation ~message_ids =
  if message_ids = [] || List.length message_ids > 4096 then reject "invalid_message_ids";
  List.iter (fun id -> if id = "" || String.length id > 256
    || String.exists (fun c -> Char.code c < 32 || Char.code c = 127) id
    then reject "invalid_message_id") message_ids;
  let selected = Hashtbl.create (List.length message_ids) in
  List.iter (fun id -> Hashtbl.replace selected id ()) message_ids;
  with_binding ~environment_id ~thread_id ~broker_root ~generation
    (fun broker state _ registration ->
      ignore (require_active state registration);
      let removed = B.drain_inbox_matching ~strict:true ~durable:true ~drained_by:"host-ack" broker
        ~session_id:state.binding.session_id ~pred:(fun m ->
          match m.message_id with Some id -> Hashtbl.mem selected id | None -> false) in
      response ["binding", binding_to_json state.binding;
        "acknowledged", `List (List.filter_map (fun m ->
          Option.map (fun id -> `String id) m.message_id) removed)])

let unbind ~environment_id ~thread_id ~broker_root ~generation =
  with_binding ~environment_id ~thread_id ~broker_root ~generation
    (fun broker state regs registration ->
      if state.active then ignore (require_active state registration);
      if state.active || registration <> None then begin
        publish_transition broker ~before:(Some state) ~after:{ state with active = false } regs
      end;
      response ["binding", binding_to_json state.binding; "unbound", `Bool true])
