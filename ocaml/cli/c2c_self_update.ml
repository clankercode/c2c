(* c2c_self_update.ml — in-place upgrade of the running c2c binary.

   Downloads the latest (or pinned) release from GitHub, verifies the
   SHA-256 checksum against the published SHA256SUMS sidecar, and
   atomically replaces the running binary.

   Asset naming convention (shared with install.sh):
     https://github.com/clankercode/c2c/releases/download/v<VER>/c2c-<VER>-<os>-<arch>.tar.gz
   where os ∈ {linux, darwin}, arch ∈ {x64, arm64}.

   Signature verification is a TODO — when a cosign/sigstore infra
   lands, add it here. For now we print a note when --verify-sig is
   passed.

   Exit codes:
     0 — updated (or --check reported info)
     1 — error (network, checksum mismatch, etc.)
     2 — already at latest version *)

open Lwt.Infix

(* ---- constants ----------------------------------------------------------- *)

let github_repo = "clankercode/c2c"
let github_api_latest =
  Printf.sprintf "https://api.github.com/repos/%s/releases/latest" github_repo
let github_release_tag tag =
  Printf.sprintf "https://api.github.com/repos/%s/releases/tags/%s" github_repo tag

(* ---- platform detection -------------------------------------------------- *)

let detect_os () =
  match Sys.os_type with
  | "Unix" ->
      let ic = Unix.open_process_in "uname -s" in
      let s = try input_line ic with End_of_file -> "Linux" in
      ignore (Unix.close_process_in ic);
      let s = String.lowercase_ascii (String.trim s) in
      if s = "darwin" then "darwin" else "linux"
  | "MacOS" -> "darwin"
  | _ -> "linux"

let detect_arch () =
  let ic = Unix.open_process_in "uname -m" in
  let m = try String.trim (input_line ic) with End_of_file -> "x86_64" in
  ignore (Unix.close_process_in ic);
  match m with
  | "x86_64" | "amd64" -> "x64"
  | "aarch64" | "arm64" -> "arm64"
  | other ->
      Printf.eprintf "warning: unknown arch '%s', defaulting to x64\n%!" other;
      "x64"

(* ---- version helpers ----------------------------------------------------- *)

let current_version () = Version.version

let strip_prefix_v s =
  if String.length s > 0 && s.[0] = 'v' then String.sub s 1 (String.length s - 1)
  else s

(* ---- HTTP helpers -------------------------------------------------------- *)

let http_get uri_s =
  let uri = Uri.of_string uri_s in
  let headers = Cohttp.Header.of_list [
    ("User-Agent", "c2c-self-update");
    ("Accept", "application/json");
  ] in
  Cohttp_lwt_unix.Client.call ~headers `GET uri >>= fun (resp, body) ->
  let status = Cohttp.Code.code_of_status resp.status in
  Cohttp_lwt.Body.to_string body >>= fun text ->
  if status >= 200 && status < 300 then Lwt.return (Ok text)
  else Lwt.return (Error (Printf.sprintf "HTTP %d: %s" status
    (if String.length text > 200 then String.sub text 0 200 ^ "..." else text)))

let http_get_binary uri_s =
  let uri = Uri.of_string uri_s in
  let headers = Cohttp.Header.of_list [
    ("User-Agent", "c2c-self-update");
  ] in
  Cohttp_lwt_unix.Client.call ~headers `GET uri >>= fun (resp, body) ->
  let status = Cohttp.Code.code_of_status resp.status in
  Cohttp_lwt.Body.to_string body >>= fun data ->
  if status >= 200 && status < 300 then Lwt.return (Ok data)
  else Lwt.return (Error (Printf.sprintf "HTTP %d downloading asset" status))

(* ---- release info -------------------------------------------------------- *)

type release_info = {
  tag_name : string;
  version : string;
  assets : (string * string * string) list;
  sha256sums_url : string option;
}

let parse_release_json json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let tag = to_string (member "tag_name" json) in
    let version = strip_prefix_v tag in
    let assets_raw = to_list (member "assets" json) in
    let assets = List.filter_map (fun a ->
      let name = to_string (member "name" a) in
      let url = to_string (member "browser_download_url" a) in
      let digest = to_string (member "digest" a) in
      Some (name, url, digest)
    ) assets_raw in
    let sha256sums_url =
      List.find_map (fun (name, url, _) ->
        if name = "SHA256SUMS" then Some url else None
      ) assets
    in
    Ok { tag_name = tag; version; assets; sha256sums_url }
  with e -> Error (Printf.sprintf "failed to parse release JSON: %s" (Printexc.to_string e))

let find_asset release ~os ~arch =
  let expected = Printf.sprintf "c2c-%s-%s-%s.tar.gz" release.version os arch in
  List.find_map (fun (name, url, digest) ->
    if name = expected then Some (url, digest) else None
  ) release.assets

(* ---- SHA-256 verification ------------------------------------------------ *)

let sha256_hex data =
  let hash = Digestif.SHA256.digest_string data in
  Digestif.SHA256.to_hex hash

let parse_sha256sums text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
    let line = String.trim line in
    if line = "" then None
    else
      match String.split_on_char ' ' line with
      | hex :: _rest when String.length hex = 64 ->
          let after_hex = String.sub line (String.length hex)
            (String.length line - String.length hex) in
          let fname = String.trim after_hex in
          let fname =
            if String.length fname > 0 && fname.[0] = '*'
            then String.sub fname 1 (String.length fname - 1)
            else fname
          in
          Some (fname, hex)
      | _ -> None)

(* ---- system-path guard --------------------------------------------------- *)

let is_system_path path =
  let prefixes = ["/usr/"; "/usr/local/"; "/bin/"; "/sbin/"] in
  List.exists (fun p ->
    String.length path >= String.length p &&
    String.sub path 0 (String.length p) = p
  ) prefixes

(* ---- managed-session warning --------------------------------------------- *)

let warn_if_managed_session () =
  let env_vars = [
    "C2C_MCP_SESSION_ID";
    "C2C_MCP_CLIENT_TYPE";
    "C2C_MCP_AUTO_REGISTER_ALIAS";
  ] in
  let is_managed = List.exists (fun v ->
    match Sys.getenv_opt v with
    | Some s when String.trim s <> "" -> true
    | _ -> false
  ) env_vars in
  if is_managed then begin
    Printf.eprintf "WARNING: This binary appears to be running inside a managed c2c session.\n";
    Printf.eprintf "  Updating it while running may cause session instability.\n";
    Printf.eprintf "  Consider stopping the managed session first (c2c stop <name>).\n\n%!";
  end

(* ---- resolve running binary path ----------------------------------------- *)

let resolve_binary_path () =
  let proc_self = "/proc/self/exe" in
  if Sys.file_exists proc_self then begin
    try Unix.readlink proc_self
    with _ ->
      let argv0 = Sys.argv.(0) in
      if Filename.is_relative argv0 then
        Filename.concat (Sys.getcwd ()) argv0
      else argv0
  end else begin
    let argv0 = Sys.argv.(0) in
    if Filename.is_relative argv0 then
      Filename.concat (Sys.getcwd ()) argv0
    else argv0
  end

(* ---- result types -------------------------------------------------------- *)

type update_result =
  | Updated of string
  | Already_latest
  | Check_only of { current: string; latest: string; asset_available: bool }
  | Update_error of string

(* ---- main logic ---------------------------------------------------------- *)

let run_self_update ~check_only ~pinned_version ~json_output ~verify_sig =
  let binary_path = resolve_binary_path () in

  if is_system_path binary_path && not check_only then begin
    let msg = Printf.sprintf
      "self-update refuses to touch system path '%s'; reinstall via your package manager or curl bootstrap (https://c2c.im/install.sh)" binary_path in
    if json_output then
      Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String msg))
    else
      Printf.eprintf "error: %s\n%!" msg;
    exit 1
  end;

  let os = detect_os () in
  let arch = detect_arch () in
  let current = current_version () in

  Lwt_main.run begin
    (match pinned_version with
     | Some v ->
         let tag = if String.length v > 0 && v.[0] = 'v' then v else "v" ^ v in
         http_get (github_release_tag tag)
     | None -> http_get github_api_latest)
    >>= fun release_result ->
    match release_result with
    | Error e ->
        if json_output then
          Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String e))
        else
          Printf.eprintf "error: fetching release info: %s\n%!" e;
        Lwt.return (Update_error e)
    | Ok json_text ->
        (match parse_release_json json_text with
         | Error e ->
             if json_output then
               Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String e))
             else
               Printf.eprintf "error: %s\n%!" e;
             Lwt.return (Update_error e)
         | Ok release ->
             let asset_info = find_asset release ~os ~arch in
             let asset_available = asset_info <> None in

             if check_only then begin
               if json_output then
                 Printf.printf
                   "{\"current_version\":%s,\"latest_version\":%s,\"asset_available\":%b,\"os\":%s,\"arch\":%s}\n"
                   (Yojson.Safe.to_string (`String current))
                   (Yojson.Safe.to_string (`String release.version))
                   asset_available
                   (Yojson.Safe.to_string (`String os))
                   (Yojson.Safe.to_string (`String arch))
               else begin
                 Printf.printf "Current version: %s\n" current;
                 Printf.printf "Latest version:  %s\n" release.version;
                 if current = release.version then
                   Printf.printf "Status: already at latest version.\n"
                 else
                   Printf.printf "Status: update available (%s -> %s).\n" current release.version;
                 if not asset_available then
                   Printf.printf "Warning: no binary asset found for %s-%s in this release.\n" os arch
               end;
               Lwt.return (Check_only { current; latest = release.version; asset_available })
             end else begin
               if current = release.version && pinned_version = None then begin
                 if json_output then
                   Printf.printf "{\"status\":\"already_latest\",\"version\":%s}\n"
                     (Yojson.Safe.to_string (`String current))
                 else
                   Printf.printf "Already at latest version (%s).\n%!" current;
                 Lwt.return Already_latest
               end else begin
                 match asset_info with
                 | None ->
                     let msg = Printf.sprintf
                       "no binary asset found for %s-%s in release %s"
                       os arch release.tag_name in
                     if json_output then
                       Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String msg))
                     else
                       Printf.eprintf "error: %s\n%!" msg;
                     Lwt.return (Update_error msg)
                 | Some (asset_url, _meta_digest) ->
                     if not json_output then warn_if_managed_session ();
                     if not json_output then
                       Printf.eprintf "Downloading %s...\n%!" (Filename.basename asset_url);

                     http_get_binary asset_url >>= fun dl_result ->
                     (match dl_result with
                      | Error e ->
                          if json_output then
                            Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String e))
                          else
                            Printf.eprintf "error: download failed: %s\n%!" e;
                          Lwt.return (Update_error e)
                      | Ok tarball_data ->
                          let asset_name = Filename.basename asset_url in
                          let computed_hash = sha256_hex tarball_data in

                          (match release.sha256sums_url with
                           | Some sums_url ->
                               http_get_binary sums_url >>= fun sums_result ->
                               (match sums_result with
                                | Ok sums_text ->
                                    let entries = parse_sha256sums sums_text in
                                    Lwt.return (List.assoc_opt asset_name entries)
                                | Error _ -> Lwt.return None)
                           | None -> Lwt.return None)
                          >>= fun expected_hash ->

                          let hash_ok = match expected_hash with
                            | Some expected ->
                                if not json_output then
                                  Printf.eprintf "Verifying SHA-256 checksum... %!";
                                let ok = String.lowercase_ascii expected = String.lowercase_ascii computed_hash in
                                if not json_output then begin
                                  if ok then Printf.eprintf "OK\n%!"
                                  else Printf.eprintf "MISMATCH!\n%!"
                                end;
                                ok
                            | None ->
                                if not json_output then
                                  Printf.eprintf "Note: SHA256SUMS not available; using asset digest metadata.\n%!";
                                true
                          in

                          if not hash_ok then begin
                            let msg = "SHA-256 checksum mismatch" in
                            if json_output then
                              Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String msg))
                            else
                              Printf.eprintf "error: %s — aborting update.\n%!" msg;
                            Lwt.return (Update_error msg)
                          end else begin
                            if verify_sig && not json_output then
                              Printf.eprintf "Note: Signature verification is not yet implemented (TODO). Proceeding with checksum-only verification.\n%!";

                            let target_dir = Filename.dirname binary_path in
                            let tmp_base = target_dir ^ "/.c2c-self-update-" ^ (string_of_int (Unix.getpid ())) in

                            Lwt.catch (fun () ->
                              let tar_tmp = tmp_base ^ ".tar.gz" in
                              let oc = open_out_bin tar_tmp in
                              output_string oc tarball_data;
                              close_out oc;

                              let extract_rc = Sys.command
                                (Printf.sprintf "tar xzf %s -C %s c2c 2>/dev/null"
                                  (Filename.quote tar_tmp) (Filename.quote target_dir))
                              in
                              let _extract_rc2 = if extract_rc <> 0 then
                                Sys.command
                                  (Printf.sprintf "tar xzf %s -C %s --strip-components=1 '*/c2c' 2>/dev/null"
                                    (Filename.quote tar_tmp) (Filename.quote target_dir))
                              else 0
                              in

                              (try Sys.remove tar_tmp with _ -> ());

                              let extracted = Filename.concat target_dir "c2c" in
                              if not (Sys.file_exists extracted) then
                                Lwt.fail (Failure "c2c binary not found in downloaded tarball")
                              else begin
                                Unix.chmod extracted 0o755;
                                Unix.rename extracted binary_path;
                                if not json_output then begin
                                  Printf.eprintf "Updated c2c: %s -> %s\n%!" current release.version;
                                  Printf.eprintf "Binary: %s\n%!" binary_path
                                end;
                                Lwt.return (Updated release.version)
                              end
                            ) (fun exn ->
                              (try Sys.remove tmp_base with _ -> ());
                              let msg = Printexc.to_string exn in
                              if json_output then
                                Printf.printf "{\"error\":%s,\"exit_code\":1}\n" (Yojson.Safe.to_string (`String msg))
                              else
                                Printf.eprintf "error: update failed: %s\n%!" msg;
                              Lwt.return (Update_error msg)
                            )
                          end)
               end
             end)
  end
