(* Swarm-wide config thunks.

   This module lives below C2c_broker and C2c_start so both can read the
   same [swarm] config keys without introducing a module-dependency cycle.
   The built-in defaults deliberately match today's hardcoded literals;
   default inversion to solo/flat-mesh values is a separate later slice. *)

let ( // ) = Filename.concat

let repo_config_path () =
  Filename.concat (Sys.getcwd ()) (".c2c" // "config.toml")

let strip_quotes (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then
    String.sub s 1 (n - 2)
  else s

let read_toml_sections_with_prefix_from_path (path : string) (prefix : string) :
    (string * (string * string) list) list =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
    let current = ref None in
    let acc = ref [] in
    let add section k v =
      let existing = Option.value (List.assoc_opt section !acc) ~default:[] in
      acc := (section, (k, v) :: existing)
             :: List.remove_assoc section !acc
    in
    (try
       while true do
         let line = input_line ic in
         let t = String.trim line in
         if t = "" || (String.length t > 0 && t.[0] = '#') then ()
         else if String.length t > 2 && t.[0] = '['
                 && t.[String.length t - 1] = ']' then begin
           let section = String.sub t 1 (String.length t - 2) in
           current :=
             if section = prefix then Some "default"
             else
               let dotted = prefix ^ "." in
               if String.length section > String.length dotted
                  && String.sub section 0 (String.length dotted) = dotted then
                 Some (String.sub section (String.length dotted)
                         (String.length section - String.length dotted))
               else None
         end else
           match !current, String.index_opt t '=' with
           | Some section, Some eq ->
               let k = String.trim (String.sub t 0 eq) in
               let v =
                 String.sub t (eq + 1) (String.length t - eq - 1)
                 |> String.trim |> strip_quotes
               in
               if k <> "" then add section k v
           | _ -> ()
       done;
       assert false
     with End_of_file ->
       List.map (fun (section, entries) -> (section, List.rev entries))
         (List.rev !acc))

let read_toml_sections_with_prefix (prefix : string) :
    (string * (string * string) list) list =
  read_toml_sections_with_prefix_from_path (repo_config_path ()) prefix

(* Built-in defaults for the swarm social room and coordinator alias.
   These deliberately match today's hardcoded literals; later slices may
   invert them to flat-mesh/solo defaults once the live swarm has pinned
   explicit overrides in .c2c/config.toml. *)
let builtin_swarm_social_room : string = "swarm-lounge"
let builtin_swarm_coordinator_alias : string = "coordinator1"

(* Read [swarm] social_room from .c2c/config.toml. Returns the configured
   room ID or [builtin_swarm_social_room] when absent/empty. *)
let swarm_config_social_room () : string =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> builtin_swarm_social_room
  | Some entries ->
      (match List.assoc_opt "social_room" entries with
       | None -> builtin_swarm_social_room
       | Some v ->
           (* trim BEFORE the empty check so a whitespace-only value ("   ")
              falls back to the builtin, not "" — otherwise the broker prepend
              sites would drop the default room. *)
           (match String.trim v with "" -> builtin_swarm_social_room | t -> t))

(* Read [swarm] coordinator_alias from .c2c/config.toml. Returns the
   configured alias or [builtin_swarm_coordinator_alias] when absent/empty. *)
let swarm_config_coordinator_alias () : string =
  let sections = read_toml_sections_with_prefix "swarm" in
  match List.assoc_opt "default" sections with
  | None -> builtin_swarm_coordinator_alias
  | Some entries ->
      (match List.assoc_opt "coordinator_alias" entries with
       | None -> builtin_swarm_coordinator_alias
       | Some v ->
           (* trim BEFORE the empty check (see swarm_config_social_room). *)
           (match String.trim v with "" -> builtin_swarm_coordinator_alias | t -> t))
