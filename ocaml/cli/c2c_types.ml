(* c2c_types.ml — shared type definitions for the c2c executable.
   Both c2c.ml and c2c_setup.ml open this module to share the same
   type definitions without circular dependencies. *)

type output_mode = Human | Json
