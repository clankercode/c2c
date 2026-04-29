(** [C2c_time] — canonical ISO-8601 UTC timestamp helpers.

    Converges ad-hoc [Unix.gmtime] + [Printf.sprintf] patterns scattered
    across the OCaml tree. See
    [.collab/research/2026-04-29-code-health-audit-cairn.md] item #7.

    The canonical format is [YYYY-MM-DDTHH:MM:SSZ] (ISO-8601 / RFC 3339).
    Variants (milliseconds, compact, bucket keys) are left as local per-site
    concerns — the divergence there is intentional. *)

(** Format a Unix timestamp as ISO-8601 UTC: [YYYY-MM-DDTHH:MM:SSZ]. *)
let iso8601_utc (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** [now_iso8601_utc ()] is [iso8601_utc (Unix.gettimeofday ())]. *)
let now_iso8601_utc () : string =
  iso8601_utc (Unix.gettimeofday ())

(** Like [iso8601_utc] but with millisecond precision:
    [YYYY-MM-DDTHH:MM:SS.mmmZ]. *)
let iso8601_utc_ms (t : float) : string =
  let tm = Unix.gmtime t in
  let ms = int_of_float ((t -. Float.round t) *. 1000.0) |> abs in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

(** Human-readable UTC: [YYYY-MM-DD HH:MM:SS UTC]. *)
let human_utc (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d UTC"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec
