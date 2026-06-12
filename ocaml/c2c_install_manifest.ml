(* c2c_install_manifest.ml — install receipt / manifest for c2c install/uninstall. *)

let ( // ) = Filename.concat

type artifact = {
  kind : string;
  path : string;
  key : string option;
  format : string option;
  begin_marker : string option;
  end_marker : string option;
  legacy_marker : string option;
  section_prefix : string option;
}

type install_record = {
  component : string;
  alias : string option;
  target_dir : string;
  c2c_version : string;
  ts : float;
  artifacts : artifact list;
}

type manifest = {
  version : int;
  installs : install_record list;
}

let manifest_path () =
  match Sys.getenv_opt "C2C_INSTALL_MANIFEST_PATH" with
  | Some p when String.trim p <> "" -> String.trim p
  | _ ->
      let base = C2c_repo_fp.xdg_state_home () // "c2c" in
      base // "install-manifest.json"

let empty_manifest () = { version = 1; installs = [] }

(* -------------------------------------------------------------------------- *)
(* Constructors *)
(* -------------------------------------------------------------------------- *)

let owned_file path =
  { kind = "owned-file"; path; key = None; format = None;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = None }

let symlink path =
  { kind = "symlink"; path; key = None; format = None;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = None }

let binary path =
  { kind = "binary"; path; key = None; format = None;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = None }

let schedule path =
  { kind = "schedule"; path; key = None; format = None;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = None }

let shared_key ~path ~key ~format =
  { kind = "shared-key"; path; key = Some key; format = Some format;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = None }

let shared_block ~path ~begin_marker ~end_marker ?legacy_marker () =
  { kind = "shared-block"; path; key = None; format = None;
    begin_marker = Some begin_marker; end_marker = Some end_marker;
    legacy_marker = legacy_marker; section_prefix = None }

let shared_toml_section ~path ~section_prefix =
  { kind = "shared-toml-section"; path; key = None; format = None;
    begin_marker = None; end_marker = None; legacy_marker = None;
    section_prefix = Some section_prefix }

(* -------------------------------------------------------------------------- *)
(* JSON serialization *)
(* -------------------------------------------------------------------------- *)

let opt_json name = function
  | Some v -> [ (name, `String v) ]
  | None -> []

let artifact_to_json a =
  `Assoc (
    [ ("kind", `String a.kind)
    ; ("path", `String a.path)
    ] @ opt_json "key" a.key
      @ opt_json "format" a.format
      @ opt_json "begin_marker" a.begin_marker
      @ opt_json "end_marker" a.end_marker
      @ opt_json "legacy_marker" a.legacy_marker
      @ opt_json "section_prefix" a.section_prefix
  )

let artifact_of_json = function
  | `Assoc fields ->
      let string_opt name =
        match List.assoc_opt name fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      { kind = (match List.assoc_opt "kind" fields with Some (`String s) -> s | _ -> "");
        path = (match List.assoc_opt "path" fields with Some (`String s) -> s | _ -> "");
        key = string_opt "key";
        format = string_opt "format";
        begin_marker = string_opt "begin_marker";
        end_marker = string_opt "end_marker";
        legacy_marker = string_opt "legacy_marker";
        section_prefix = string_opt "section_prefix" }
  | _ ->
      { kind = ""; path = ""; key = None; format = None;
        begin_marker = None; end_marker = None; legacy_marker = None;
        section_prefix = None }

let record_to_json r =
  `Assoc (
    [ ("component", `String r.component)
    ; ("target_dir", `String r.target_dir)
    ; ("c2c_version", `String r.c2c_version)
    ; ("ts", `Float r.ts)
    ; ("artifacts", `List (List.map artifact_to_json r.artifacts))
    ] @ match r.alias with
        | Some a -> [ ("alias", `String a) ]
        | None -> []
  )

let record_of_json = function
  | `Assoc fields ->
      let component =
        match List.assoc_opt "component" fields with Some (`String s) -> s | _ -> "" in
      let target_dir =
        match List.assoc_opt "target_dir" fields with Some (`String s) -> s | _ -> "" in
      let c2c_version =
        match List.assoc_opt "c2c_version" fields with Some (`String s) -> s | _ -> "" in
      let ts =
        match List.assoc_opt "ts" fields with
        | Some (`Float f) -> f
        | Some (`Int i) -> float_of_int i
        | _ -> 0.0 in
      let alias =
        match List.assoc_opt "alias" fields with Some (`String s) -> Some s | _ -> None in
      let artifacts =
        match List.assoc_opt "artifacts" fields with
        | Some (`List xs) -> List.map artifact_of_json xs
        | _ -> [] in
      { component; alias; target_dir; c2c_version; ts; artifacts }
  | _ -> { component = ""; target_dir = ""; c2c_version = ""; ts = 0.0;
           alias = None; artifacts = [] }

let manifest_to_json m =
  `Assoc
    [ ("version", `Int m.version)
    ; ("installs", `List (List.map record_to_json m.installs))
    ]

let manifest_of_json = function
  | `Assoc fields ->
      let version =
        match List.assoc_opt "version" fields with
        | Some (`Int i) -> i
        | _ -> 1 in
      let installs =
        match List.assoc_opt "installs" fields with
        | Some (`List xs) -> List.map record_of_json xs
        | _ -> [] in
      { version; installs }
  | _ -> empty_manifest ()

(* -------------------------------------------------------------------------- *)
(* Atomic, flock-guarded I/O *)
(* -------------------------------------------------------------------------- *)

let read_manifest () =
  let path = manifest_path () in
  if not (Sys.file_exists path) then empty_manifest ()
  else
    match C2c_io.read_json_opt path with
    | None -> empty_manifest ()
    | Some json ->
        try manifest_of_json json with
        | _ -> empty_manifest ()

let with_file_lock path f =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      (try Unix.close fd with _ -> ()))
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      f ())

let write_manifest m =
  let path = manifest_path () in
  C2c_io.mkdir_p (Filename.dirname path);
  let lock_path = path ^ ".lock" in
  C2c_io.mkdir_p (Filename.dirname lock_path);
  let json = manifest_to_json m in
  with_file_lock lock_path (fun () ->
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc =
      open_out_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_text ]
        0o600 tmp
    in
    let cleanup () = try Unix.unlink tmp with _ -> () in
    try
      Fun.protect
        ~finally:(fun () -> try close_out oc with _ -> ())
        (fun () ->
           Yojson.Safe.to_channel oc json;
           flush oc;
           (try Unix.fsync (Unix.descr_of_out_channel oc) with Unix.Unix_error _ -> ()));
      Unix.rename tmp path
    with e ->
      cleanup ();
      raise e)

let upsert_record ~record =
  let m = read_manifest () in
  let filtered =
    List.filter
      (fun r ->
         not (r.component = record.component && r.target_dir = record.target_dir))
      m.installs
  in
  write_manifest { m with installs = filtered @ [ record ] }

let remove_record ~component ~target_dir =
  let m = read_manifest () in
  let filtered =
    List.filter
      (fun r -> not (r.component = component && r.target_dir = target_dir))
      m.installs
  in
  if List.length filtered <> List.length m.installs then
    write_manifest { m with installs = filtered }
