(* Banner — themed ASCII-art banner for c2c CLI commands *)

type theme = {
  name : string;
  accent : string;
  muted : string;
  reset : string;
}

let themes : (string, theme) Hashtbl.t = Hashtbl.create 16

let () =
  List.iter (fun (k, v) -> Hashtbl.add themes k v) [
    "exp33-gilded",   { name = "EXP33 GILDED";   accent = "\027[38;5;221m"; muted = "\027[38;5;142m"; reset = "\027[0m" };
    "exp33-black",    { name = "EXP33 BLACK";    accent = "\027[38;5;255m"; muted = "\027[38;5;240m"; reset = "\027[0m" };
    "exp33-chroma",   { name = "EXP33 CHROMA";   accent = "\027[38;5;201m"; muted = "\027[38;5;39m";  reset = "\027[0m" };
    "ffx-yuna",       { name = "FFX YUNA";       accent = "\027[38;5;183m"; muted = "\027[38;5;110m"; reset = "\027[0m" };
    "ffx-rikku",      { name = "FFX RIKKU";      accent = "\027[38;5;226m"; muted = "\027[38;5;29m";  reset = "\027[0m" };
    "ffx-bevelle",    { name = "FFX BEVELLE";    accent = "\027[38;5;81m";  muted = "\027[38;5;58m";  reset = "\027[0m" };
    "ffx-zanarkand",  { name = "FFX ZANARKAND";  accent = "\027[38;5;208m"; muted = "\027[38;5;130m"; reset = "\027[0m" };
    "lotr-forge",     { name = "LOTR FORGE";     accent = "\027[38;5;137m"; muted = "\027[38;5;94m";  reset = "\027[0m" };
    "er-ranni",       { name = "ER Ranni";        accent = "\027[38;5;117m"; muted = "\027[38;5;60m";  reset = "\027[0m" };
    "er-nightreign",  { name = "ER NIGHTREIGN";  accent = "\027[38;5;225m"; muted = "\027[38;5;91m";  reset = "\027[0m" };
    "er-melina",      { name = "ER MELINA";       accent = "\027[38;5;216m"; muted = "\027[38;5;137m"; reset = "\027[0m" };
    "default",        { name = "c2c";             accent = "\027[36m";       muted = "\027[2m";        reset = "\027[0m" };
  ]

let get_theme (theme_name:string option) : theme =
  match theme_name with
  | Some t -> (match Hashtbl.find_opt themes t with Some th -> th | None -> Hashtbl.find themes "default")
  | None -> Hashtbl.find themes "default"

let timestamp () =
  (* human_utc already includes " UTC" — no need to append *)
  C2c_time.human_utc (Unix.gettimeofday ())

let pad_right (s:string) (n:int) : string =
  if String.length s >= n then String.sub s 0 n
  else s ^ String.make (n - String.length s) ' '

(* Count the printable width of a string — strips ANSI CSI escape sequences
   so that color-tinted text doesn't throw off column math. *)
let visible_width (s:string) : int =
  let n = String.length s in
  let i = ref 0 and w = ref 0 in
  while !i < n do
    if !i + 1 < n && s.[!i] = '\027' && s.[!i + 1] = '[' then begin
      (* Skip ESC [ ... <final-byte> where final-byte is 0x40..0x7E. *)
      i := !i + 2;
      while !i < n && not (let c = Char.code s.[!i] in c >= 0x40 && c <= 0x7E) do incr i done;
      if !i < n then incr i
    end else begin
      incr i; incr w
    end
  done;
  !w

(* Print `content` on a bordered row; pad with spaces to reach `inner`
   printable columns inside the walls. Works regardless of ANSI codes
   embedded in content. Caller supplies any color prefix/suffix as part
   of content; only the visible characters count toward width. *)
let box_row ~wall_color ~reset ~inner content =
  let pad_n = inner - visible_width content in
  let pad_n = if pad_n < 0 then 0 else pad_n in
  print_string wall_color;
  print_string "|";
  print_string reset;
  print_string content;
  print_string (String.make pad_n ' ');
  print_string wall_color;
  print_string "|";
  print_string reset;
  print_newline ()

let print_banner ?theme_name ?subtitle cmd_name =
  let t = get_theme theme_name in
  let a = t.accent in
  let m = t.muted in
  let r = t.reset in
  (* Total interior width (between the two `|` walls). All body rows pad
     their content to exactly this number of printable columns so every
     wall lands on the same screen column as the `+` corners. *)
  let inner = 56 in
  let hr = String.make inner '=' in
  print_newline ();
  print_string a; print_string "+"; print_string hr; print_string "+"; print_string r; print_newline ();
  box_row ~wall_color:a ~reset:r ~inner (" " ^ cmd_name);
  (match subtitle with
   | Some s ->
       box_row ~wall_color:a ~reset:r ~inner ("  " ^ m ^ s ^ r)
   | None -> ());
  print_string a; print_string "+"; print_string hr; print_string "+"; print_string r; print_newline ();
  box_row ~wall_color:a ~reset:r ~inner " c2c peer-to-peer messaging for AI agents";
  box_row ~wall_color:a ~reset:r ~inner ("  " ^ m ^ timestamp () ^ r);
  print_string a; print_string "+"; print_string hr; print_string "+"; print_string r; print_newline ();
  print_newline ();
  flush stdout

let print_progress ?theme_name msg =
  let t = get_theme theme_name in
  print_string t.muted;
  print_char '\r';
  print_string "[";
  print_string (timestamp ());
  print_string "]";
  print_string t.reset;
  print_char ' ';
  print_string t.accent;
  print_string msg;
  print_string "...";
  print_string t.reset;
  flush stdout

let print_done ?theme_name msg =
  let t = get_theme theme_name in
  print_string t.muted;
  print_char '\r';
  print_string "[";
  print_string (timestamp ());
  print_string "]";
  print_string t.reset;
  print_string " ";
  print_string t.accent;
  print_string "OK";
  print_string t.reset;
  print_string " ";
  print_string msg;
  print_newline ();
  flush stdout

let print_error ?theme_name msg =
  let t = get_theme theme_name in
  print_string t.muted;
  print_char '\r';
  print_string "[";
  print_string (timestamp ());
  print_string "]";
  print_string "\027[31m";
  print_string " ERROR ";
  print_string t.reset;
  print_string " ";
  print_string msg;
  print_newline ();
  flush stdout
