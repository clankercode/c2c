let version = "0.6.10"

let build_date =
  match Sys.getenv_opt "BUILD_DATE" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> "dev"
