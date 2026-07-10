(* c2c_self_update_provenance.ml — package-manager provenance detection +
   delegation policy for `c2c self-update` (B101 / A003 / F101).

   Pure and hermetic: callers inject the running binary realpath, the realpath
   resolved on PATH, and manager availability, so unit tests never touch a real
   package manager, filesystem, or the network. *)

type install_method =
  | Standalone
  | Npm
  | Pnpm
  | Bun
  | Unknown

let string_of_method = function
  | Standalone -> "standalone"
  | Npm -> "npm"
  | Pnpm -> "pnpm"
  | Bun -> "bun"
  | Unknown -> "unknown"

let package_name = "@clanker-code/c2c"

(* ---- pure path helpers --------------------------------------------------- *)

let lower = String.lowercase_ascii

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else begin
    let rec loop i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  end

let segments path =
  String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let has_segment path seg = List.mem seg (segments path)

(* ---- classification ------------------------------------------------------ *)

(* Precedence matters: a pnpm/bun store also contains a `node_modules` segment,
   so the more specific markers are tested before the generic npm one. *)
let classify_path path =
  let p = lower path in
  if has_segment p ".pnpm" then Pnpm
  else if has_segment p ".bun" then Bun
  else if has_segment p "node_modules" then Npm
  else Standalone

let owns_our_package path =
  (* npm/bun keep the scoped dir "@clanker-code/c2c"; pnpm mangles it to
     "@clanker-code+c2c". The shared "clanker-code" token covers both. *)
  contains ~needle:"clanker-code" (lower path)

(* ---- detection ----------------------------------------------------------- *)

type t = {
  method_ : install_method;
  binary_path : string;
  package_name : string;
  shadowed_by : string option;
}

let detect ~binary_path ~resolved_on_path =
  let base = classify_path binary_path in
  let method_ =
    match base with
    | Standalone -> Standalone
    | (Npm | Pnpm | Bun) as m ->
        (* In a package store but not our package -> ambiguous, refuse. *)
        if owns_our_package binary_path then m else Unknown
    | Unknown -> Unknown
  in
  let shadowed_by =
    match resolved_on_path with
    | Some p when p <> "" && p <> binary_path -> Some p
    | _ -> None
  in
  { method_; binary_path; package_name; shadowed_by }

let is_package_managed = function
  | Npm | Pnpm | Bun -> true
  | Standalone | Unknown -> false

(* ---- delegation ---------------------------------------------------------- *)

let strip_prefix_v s =
  if String.length s > 0 && (s.[0] = 'v' || s.[0] = 'V')
  then String.sub s 1 (String.length s - 1)
  else s

let version_selector = function
  | None -> "@latest"
  | Some v -> "@" ^ strip_prefix_v (String.trim v)

let delegate_command method_ ~pinned =
  let sel = version_selector pinned in
  match method_ with
  | Npm -> Some (Printf.sprintf "npm install -g %s%s" package_name sel)
  | Pnpm -> Some (Printf.sprintf "pnpm add -g %s%s" package_name sel)
  | Bun -> Some (Printf.sprintf "bun add -g %s%s" package_name sel)
  | Standalone | Unknown -> None

let manager_binary = function
  | Npm -> Some "npm"
  | Pnpm -> Some "pnpm"
  | Bun -> Some "bun"
  | Standalone | Unknown -> None

(* ---- policy -------------------------------------------------------------- *)

type action =
  | In_place_standalone
  | Delegate of { method_ : install_method; command : string }
  | Refuse of string

let unknown_message t =
  Printf.sprintf
    "c2c is running from a package store this updater does not recognise (%s); \
     reinstall with your package manager or the standalone installer at \
     https://c2c.im/install.sh"
    t.binary_path

let shadow_message t shadow =
  Printf.sprintf
    "refusing to self-update: the running binary (%s) is not the c2c that runs \
     from your PATH (%s); update that one instead or remove the shadowing entry"
    t.binary_path shadow

let missing_manager_message method_ ~command =
  let mgr =
    match manager_binary method_ with Some m -> m | None -> "the package manager"
  in
  Printf.sprintf
    "c2c was installed via %s but '%s' is not on PATH; install it and run: %s"
    (string_of_method method_) mgr command

let plan t ~check_only ~pinned ~manager_available =
  match t.method_ with
  | Unknown -> Refuse (unknown_message t)
  | Standalone ->
      (match t.shadowed_by with
       | Some shadow when not check_only -> Refuse (shadow_message t shadow)
       | _ -> In_place_standalone)
  | (Npm | Pnpm | Bun) as m ->
      let command =
        match delegate_command m ~pinned with Some c -> c | None -> ""
      in
      if check_only then
        (* --check must never mutate and must not require the manager present:
           it only reports what would run. *)
        Delegate { method_ = m; command }
      else if not manager_available then
        Refuse (missing_manager_message m ~command)
      else
        Delegate { method_ = m; command }

(* ---- rendering ----------------------------------------------------------- *)

let describe t =
  match t.method_ with
  | Standalone ->
      Printf.sprintf "standalone binary at %s (in-place update)" t.binary_path
  | Npm | Pnpm | Bun ->
      Printf.sprintf "%s-managed install (%s)"
        (string_of_method t.method_) package_name
  | Unknown ->
      Printf.sprintf "unrecognised package store at %s" t.binary_path

let to_json t ~pinned =
  `Assoc
    [ ("install_method", `String (string_of_method t.method_));
      ("binary_path", `String t.binary_path);
      ("package_name", `String t.package_name);
      ( "delegate_command",
        (match delegate_command t.method_ ~pinned with
         | Some c -> `String c
         | None -> `Null) );
      ( "shadowed_by",
        (match t.shadowed_by with Some p -> `String p | None -> `Null) ) ]

let delegate_outcome_message method_ ~command ~rc =
  if rc = 0 then
    Printf.sprintf "c2c updated via %s (%s)" (string_of_method method_) command
  else
    Printf.sprintf "delegated update via %s failed (exit %d): %s"
      (string_of_method method_) rc command
