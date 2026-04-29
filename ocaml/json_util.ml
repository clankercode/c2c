(** [Json_util] — tiny pure-option JSON accessors.

    Lives early in the [c2c_mcp] library's module chain so it is reachable
    from every other module in the library (relay, c2c_start, c2c_mcp
    itself) as well as the [c2c] executable.

    Audit #388: converges three previously-duplicated [string_member]
    helpers — [c2c_mcp.ml]'s required-string variant, [c2c_mcp.ml]'s
    [optional_string_member], and [c2c_start.ml]'s strict-Some-only
    variant — onto a single canonical option-returning helper. Strict
    callers (raise-on-missing) wrap [string_member] at the call site;
    we deliberately avoid baking the raise into this module so the
    pure data-access layer stays exception-free. *)

(** [assoc_opt name json] — list-assoc on [`Assoc fields], None
    otherwise. Matches the local helper that lived in [c2c_start.ml]. *)
let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

(** [string_member name json] returns [Some s] iff [json] is an object
    whose [name] field is a JSON string. Strict: integers, floats, bools,
    nulls, and missing keys all yield [None]. Empty strings ARE returned
    as [Some ""]; callers that want trim-to-None semantics should compose
    with [String.trim]. *)
let string_member name json =
  match assoc_opt name json with
  | Some (`String value) -> Some value
  | _ -> None

(** [string_member_any names json] tries each name in order and returns
    the first that is present and non-empty (after [String.trim]).
    Used for tool-arg parsing where multiple aliases are accepted
    (e.g. [to_alias] vs [alias]). *)
let string_member_any names json =
  let rec find = function
    | [] -> None
    | name :: rest ->
        (match string_member name json with
         | Some s when String.trim s <> "" -> Some s
         | _ -> find rest)
  in
  find names

(** [int_member name json] returns [Some i] iff the field is a JSON int. *)
let int_member name json =
  match assoc_opt name json with
  | Some (`Int i) -> Some i
  | _ -> None

(** [bool_member name json] returns [Some b] iff the field is a JSON bool. *)
let bool_member name json =
  match assoc_opt name json with
  | Some (`Bool b) -> Some b
  | _ -> None
