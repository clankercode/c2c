(lang dune 3.21)

(name c2c)

(package
 (name c2c)
 (depends dune cmdliner yojson lwt logs alcotest cohttp-lwt-unix uuidm
          base64 digestif mirage-crypto-ec mirage-crypto-rng
          tls-lwt mirage-crypto-rng-lwt ca-certs)
 (allow_empty))
