(* Recipe parity PoC: port the extension's computeHostHash() to OCaml
   and verify it produces the same value byte-for-byte on this machine.

   This file lives at ocaml/tools/host_id_poc.ml as a recipe-parity
   reference. It is NOT the production implementation — the production
   `c2c host-id` subcommand (planned in slice 1 of
   .collab/design/2026-06-17-c2c-opaque-host-id.md) should be a proper
   c2c CLI command that calls into the same code path as the extension.

   To compile and run:
     ocamlfind ocamlopt -package unix -linkpkg -o host_id_poc host_id_poc.ml
     ./host_id_poc

   Expected output (on this machine, 2026-06-17):
     host_hash: 3d08761ae3f3
     hostname: xsm
     machine_id: f59bb56bdbc74dc9a151ad27fdd4a94d

   The extension's `pi-c2c/src/relay.ts:computeHostHash()` produces the
   same `3d08761ae3f3` — recipe parity confirmed. *)

let try_read_file path =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    let trimmed = String.trim s in
    if String.length trimmed > 0 then Some trimmed else None
  with _ -> None

(* Port of pi-c2c/src/relay.ts:pickHostSource (single-source primary + fallback) *)
let pick_host_source () =
  let try_str kind str =
    let trimmed = String.trim str in
    if String.length trimmed > 0 then Some (kind, trimmed) else None
  in
  match try_read_file "/sys/class/dmi/id/product_uuid" with
  | Some v -> Some ("product_uuid", v)
  | None -> (
    match try_read_file "/etc/machine-id" with
    | Some v -> Some ("machine_id", v)
    | None -> (
      match try_str "hostname" (Unix.gethostname ()) with
      | Some v -> Some v
      | None -> None
    )
  )

(* Port of pi-c2c/src/relay.ts:computeHostHash (12-hex SHA256, kind-prefixed) *)
let compute_host_hash () =
  match pick_host_source () with
  | Some (kind, value) ->
    let input = Printf.sprintf "%s=%s" kind value in
    (* For this PoC, we shell out to sha256sum rather than link a hash lib.
       The production code should use a vendored SHA256 (e.g. digestif). *)
    let ic = Unix.open_process_in
      (Printf.sprintf "printf '%%s' %s | sha256sum | cut -c1-12"
        (Filename.quote input)) in
    let result = input_line ic in
    close_in ic;
    String.sub result 0 12
  | None -> "000000000000"

let () =
  let h = compute_host_hash () in
  Printf.printf "host_hash: %s\n" h;
  let me = Unix.gethostname () in
  Printf.printf "hostname: %s\n" me;
  match try_read_file "/etc/machine-id" with
  | Some m -> Printf.printf "machine_id: %s\n" m
  | None -> Printf.printf "machine_id: <not readable>\n"
