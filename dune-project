(lang dune 3.21)

(name c2c)

(package
 (name c2c)
 (depends dune cmdliner yojson lwt logs alcotest cohttp-lwt-unix uuidm
          base64 digestif mirage-crypto-ec mirage-crypto-rng)
 (allow_empty))
