(* B112: alias word pool tests.

   The pool lives in [C2c_alias_words] (single source module, generated
   from data/c2c_alias_words.txt + data/c2c_alias_words_easy.txt via
   `just codegen-alias-words`). These tests pin:
   - a pool-size floor (the whole point of B112 was collision headroom);
   - word validity (lowercase alnum, no hyphens — hyphen is the alias
     separator — reasonable length);
   - uniqueness (alias comparisons are case-insensitive);
   - easy_pool being a strict subset of the full pool;
   - zero drift between the embedded arrays and the data files;
   - generate_alias actually drawing from the embedded pool. *)

open Alcotest

let words = C2c_alias_words.words
let easy = C2c_alias_words.easy_pool

let is_valid_word w =
  let n = String.length w in
  n >= 3 && n <= 12
  && (match w.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | '0' .. '9' -> true | _ -> false) w

let module_of_array arr = Array.to_list arr

let read_lines path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | line ->
            let line = String.trim line in
            if line = "" then loop acc else loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

(* Tests run with cwd = _build/default/ocaml/test; the data files are
   declared as dune deps so they are present in the sandbox. *)
let full_pool_file = "../../data/c2c_alias_words.txt"
let easy_pool_file = "../../data/c2c_alias_words_easy.txt"

let test_pool_size_floor () =
  let n = Array.length words in
  check bool (Printf.sprintf "pool has >= 1000 words (got %d)" n) true (n >= 1000)

let test_easy_pool_size_floor () =
  let n = Array.length easy in
  check bool (Printf.sprintf "easy pool has >= 40 words (got %d)" n) true (n >= 40)

let test_words_valid () =
  Array.iter
    (fun w ->
      check bool
        (Printf.sprintf "word %S is lowercase alnum, 3..12 chars, no hyphen" w)
        true (is_valid_word w))
    words

let test_words_unique_case_insensitive () =
  (* Alias comparisons are case-insensitive; the pool must be unique
     under lowercase folding (words are already lowercase per
     test_words_valid, so this is plain uniqueness with a belt). *)
  let tbl = Hashtbl.create (Array.length words) in
  Array.iter
    (fun w ->
      let k = String.lowercase_ascii w in
      check bool (Printf.sprintf "word %S is unique (case-insensitive)" w) false
        (Hashtbl.mem tbl k);
      Hashtbl.replace tbl k ())
    words

let test_easy_pool_subset_of_words () =
  let full = Hashtbl.create (Array.length words) in
  Array.iter (fun w -> Hashtbl.replace full w ()) words;
  Array.iter
    (fun w ->
      check bool (Printf.sprintf "easy word %S is in the full pool" w) true
        (Hashtbl.mem full w))
    easy;
  (* STRICT subset: the easy pool must be materially smaller than the full
     pool, so an accidental easy==full data-file swap fails loudly. *)
  check bool
    (Printf.sprintf "easy pool (%d) is strictly smaller than full pool (%d)"
       (Array.length easy) (Array.length words))
    true
    (Array.length easy < Array.length words)

let test_words_match_data_file () =
  let from_file = read_lines full_pool_file in
  check (list string) "embedded words == data/c2c_alias_words.txt" from_file
    (module_of_array words)

let test_easy_pool_matches_data_file () =
  let from_file = read_lines easy_pool_file in
  check (list string) "embedded easy_pool == data/c2c_alias_words_easy.txt"
    from_file (module_of_array easy)

let test_generate_alias_draws_from_pool () =
  let full = Hashtbl.create (Array.length words) in
  Array.iter (fun w -> Hashtbl.replace full w ()) words;
  for _ = 1 to 200 do
    let a = C2c_start.generate_alias ~no_nonce:true () in
    match String.split_on_char '-' a with
    | [ w1; w2 ] ->
        check bool (Printf.sprintf "alias %S word 1 in pool" a) true (Hashtbl.mem full w1);
        check bool (Printf.sprintf "alias %S word 2 in pool" a) true (Hashtbl.mem full w2);
        check bool (Printf.sprintf "alias %S words differ" a) false (w1 = w2)
    | _ -> fail (Printf.sprintf "alias %S is not <word>-<word>" a)
  done

let () =
  run "c2c_alias_words"
    [ ( "pool_b112",
        [ ("pool_size_floor", `Quick, test_pool_size_floor)
        ; ("easy_pool_size_floor", `Quick, test_easy_pool_size_floor)
        ; ("words_valid", `Quick, test_words_valid)
        ; ("words_unique_case_insensitive", `Quick, test_words_unique_case_insensitive)
        ; ("easy_pool_subset_of_words", `Quick, test_easy_pool_subset_of_words)
        ; ("words_match_data_file", `Quick, test_words_match_data_file)
        ; ("easy_pool_matches_data_file", `Quick, test_easy_pool_matches_data_file)
        ; ("generate_alias_draws_from_pool", `Quick, test_generate_alias_draws_from_pool)
        ] )
    ]
