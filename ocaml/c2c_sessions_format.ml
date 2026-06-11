(* Pure formatters for the `c2c sessions` discovery command (design §6).
   No I/O, no broker state — takes a registration list and returns either a
   JSON value or a human-readable string. Living in the c2c_mcp library so
   ocaml/test/test_c2c_sessions.ml can exercise the real code path. *)

open C2c_mcp_helpers

let liveness_label (s : C2c_mcp.Broker.liveness_state) : string =
  match s with
  | C2c_mcp.Broker.Alive -> "alive"
  | C2c_mcp.Broker.Dead -> "dead"
  | C2c_mcp.Broker.Unknown -> "?"

let liveness_json (s : C2c_mcp.Broker.liveness_state) : Yojson.Safe.t =
  match s with
  | C2c_mcp.Broker.Alive -> `Bool true
  | C2c_mcp.Broker.Dead -> `Bool false
  | C2c_mcp.Broker.Unknown -> `Null

(* Truncate a string to n chars, appending "…" if shortened. *)
let truncate (s : string) (n : int) : string =
  if String.length s <= n then s
  else if n <= 1 then String.sub s 0 (max 0 n)
  else String.sub s 0 (n - 1) ^ "…"

(* Display alias: prefer canonical_alias (fully-qualified) when present. *)
let display_alias (r : C2c_mcp.registration) : string =
  Option.value r.canonical_alias ~default:r.alias

(* Truncate a session_id to 34 chars (typical UUIDs are 36). *)
let display_session_id (r : C2c_mcp.registration) : string =
  let s = r.session_id in
  if String.length s > 34 then String.sub s 0 34 ^ "…" else s

let liveness_of (r : C2c_mcp.registration) : C2c_mcp.Broker.liveness_state =
  C2c_mcp.Broker.registration_liveness_state r

(* --- JSON output --------------------------------------------------------- *)

let session_to_json (r : C2c_mcp.registration) : Yojson.Safe.t =
  let base : (string * Yojson.Safe.t) list =
    [ ("session_id", `String r.session_id)
    ; ("alias", `String (display_alias r))
    ; ("client_type", (match r.client_type with
                        | Some ct -> `String ct
                        | None -> `Null))
    ; ("cwd", (match r.cwd with
                | Some c -> `String c
                | None -> `Null))
    ; ("alive", liveness_json (liveness_of r))
    ]
  in
  let with_role = match r.role with
    | Some role -> base @ [("role", `String role)]
    | None -> base
  in
  `Assoc with_role

let sessions_to_json (regs : C2c_mcp.registration list) : Yojson.Safe.t =
  `List (List.map session_to_json regs)

(* --- Human-readable output ----------------------------------------------- *)

(* Column widths: chosen so a typical UUID (36 chars) and a 20-char alias
   fit without truncation; longer values are truncated with "…". *)
let col_sid = 36
let col_alias = 20
let col_client = 10
let col_state = 5
let col_cwd = 30

let header () : string =
  Printf.sprintf "  %-36s %-20s %-10s %-5s %-30s %s\n"
    "SESSION_ID" "ALIAS" "CLIENT" "STATE" "CWD" "ROLE"

let separator () : string =
  Printf.sprintf "  %-36s %-20s %-10s %-5s %-30s %s\n"
    (String.make col_sid '-')
    (String.make col_alias '-')
    (String.make col_client '-')
    (String.make col_state '-')
    (String.make col_cwd '-')
    "----"

let session_row (r : C2c_mcp.registration) : string =
  let ct = Option.value r.client_type ~default:"?" in
  let cwd = Option.value r.cwd ~default:"-" in
  let role_str = Option.value r.role ~default:"" in
  Printf.sprintf "  %-36s %-20s %-10s %-5s %-30s %s\n"
    (display_session_id r)
    (truncate (display_alias r) col_alias)
    ct
    (liveness_label (liveness_of r))
    (truncate cwd col_cwd)
    role_str

let format_human (regs : C2c_mcp.registration list) : string =
  match regs with
  | [] -> "No sessions.\n"
  | _ -> header () ^ separator () ^ String.concat "" (List.map session_row regs)
