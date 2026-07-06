(* c2c_stats_cmd - stats command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

let stats_cmd =
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Filter to a single agent alias.")
  in
  let since_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"DUR"
      ~doc:"Only count messages within this duration (e.g. 1h, 30m, 7d).")
  in
  let append_sitrep_flag =
    Cmdliner.Arg.(value & flag & info [ "append-sitrep" ]
      ~doc:"Append or replace a Swarm stats section in the current UTC hourly sitrep.")
  in
  let top_flag =
    Cmdliner.Arg.(value & opt (some int) None & info [ "top"; "t" ] ~docv:"N"
      ~doc:"Show only the top N agents by total message count.")
  in
  let+ json = json_flag
  and+ alias_filter = alias_flag
  and+ since_str = since_flag
  and+ append_sitrep = append_sitrep_flag
  and+ top_n = top_flag in
  let root = resolve_broker_root () in
  C2c_stats.run ~root ~json ~alias_filter ~since_str ~append_sitrep ~top_n

let markdown_flag =
  Cmdliner.Arg.(value & flag & info [ "markdown"; "m" ]
    ~doc:"Output stats as grouped markdown tables with per-day totals.")

let csv_flag =
  Cmdliner.Arg.(value & flag & info [ "csv"; "c" ]
    ~doc:"Output stats as CSV (columns: day,alias,msgs_out,msgs_in). This is the default.")

let compact_flag =
  Cmdliner.Arg.(value & flag & info [ "compact" ]
    ~doc:"Output compact (non-pretty) JSON when used with --json.")

let stats_history_cmd =
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Filter to a single agent alias.")
  in
  let days_flag =
    Cmdliner.Arg.(value & opt int 7 & info [ "days"; "d" ] ~docv:"N"
      ~doc:"Lookback window in days (0 = all archive history).")
  in
  let bucket_flag =
    Cmdliner.Arg.(value & opt string "day" & info [ "bucket"; "b" ] ~docv:"GRAIN"
      ~doc:"Bucket granularity: hour | day | week (default: day).")
  in
  let top_flag =
    Cmdliner.Arg.(value & opt (some int) None & info [ "top"; "t" ] ~docv:"N"
      ~doc:"Keep only the top-N busiest aliases per bucket, ranked by msgs_out + msgs_in.")
  in
  let+ json = json_flag
  and+ markdown = markdown_flag
  and+ csv = csv_flag
  and+ compact = compact_flag
  and+ alias_filter = alias_flag
  and+ days = days_flag
  and+ bucket = bucket_flag
  and+ top = top_flag in
  let grain = match C2c_stats.parse_bucket bucket with
    | Some g -> g
    | None ->
        Printf.eprintf "error: --bucket must be hour|day|week (got %S)\n%!" bucket;
        exit 1
  in
  let root = resolve_broker_root () in
  C2c_stats.run_history ~root ~json ~markdown ~csv ~compact ~alias_filter ~days ~grain ~top_n:top ()

let stats : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.group
    ~default:stats_cmd
    (Cmdliner.Cmd.info "stats" ~doc:"Show per-agent message statistics across the swarm.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "history"
        ~doc:"Per-day rollup of swarm message counts (CSV by default; --json for JSON; --markdown for grouped markdown tables; --csv for explicit CSV; --compact for compact JSON).")
        stats_history_cmd ]
