(* c2c_types.ml — shared type definitions for the c2c executable.
   Both c2c.ml and c2c_setup.ml open this module to share the same
   type definitions without circular dependencies. *)

type output_mode = Human | Json

(* Command safety tiers — used by c2c_commands.ml for tier filtering. *)
type safety =
  | Tier1  (* safe for agents: read-only queries, messaging, polling *)
  | Tier2  (* safe with care: side effects, process lifecycle *)
  | Tier3  (* unsafe for agents: systemic impact, requires external context *)
  | Tier4  (* internal plumbing: never shown without --all *)

(* Managed instance view — used by health, instances, and start commands. *)
type managed_instance_view =
  { mi_name : string
  ; mi_client : string
  ; mi_status : string
  ; mi_delivery_mode : string
  ; mi_pid : int option
  ; mi_created_at : float option
  ; mi_tmux_location : string option
  ; mi_expected_cwd : string option
  ; mi_role : string option
  }
