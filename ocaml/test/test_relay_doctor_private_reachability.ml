(* Hermetic tests for B266 doctor private-reachability checks (pure Relay_doctor). *)

open Alcotest

let status_eq = check bool

let health ~auth_mode ?contact_protocol ?private_reachability () =
  let fields =
    [ ("ok", `Bool true); ("auth_mode", `String auth_mode) ]
  in
  let fields =
    match contact_protocol with
    | Some n -> ("contact_protocol", `Int n) :: fields
    | None -> fields
  in
  let fields =
    match private_reachability with
    | Some s -> ("private_reachability", `String s) :: fields
    | None -> fields
  in
  `Assoc fields

let test_auth_mode_prod_pass () =
  let r =
    Relay_doctor.check_auth_mode ~health:(Some (health ~auth_mode:"prod" ()))
  in
  status_eq "prod Pass" true (r.status = Relay_doctor.Pass)

let test_auth_mode_dev_fail () =
  let r =
    Relay_doctor.check_auth_mode ~health:(Some (health ~auth_mode:"dev" ()))
  in
  status_eq "dev Fail" true (r.status = Relay_doctor.Fail)

let test_contact_protocol_missing_fail () =
  let r =
    Relay_doctor.check_contact_protocol
      ~health:(Some (health ~auth_mode:"prod" ()))
  in
  status_eq "missing contact_protocol Fail" true (r.status = Relay_doctor.Fail)

let test_contact_protocol_ok () =
  let r =
    Relay_doctor.check_contact_protocol
      ~health:(Some (health ~auth_mode:"prod" ~contact_protocol:1 ()))
  in
  status_eq "contact_protocol 1 Pass" true (r.status = Relay_doctor.Pass)

let test_private_reachability_prod_pass () =
  let r =
    Relay_doctor.check_private_reachability
      ~health:
        (Some
           (health ~auth_mode:"prod" ~private_reachability:"consent_gated" ()))
  in
  status_eq "consent_gated+prod Pass" true (r.status = Relay_doctor.Pass)

let test_private_reachability_dev_inconclusive () =
  let r =
    Relay_doctor.check_private_reachability
      ~health:
        (Some
           (health ~auth_mode:"dev" ~private_reachability:"consent_gated" ()))
  in
  status_eq "consent_gated+dev Inconclusive" true
    (r.status = Relay_doctor.Inconclusive)

let test_private_reachability_missing_fail () =
  let r =
    Relay_doctor.check_private_reachability
      ~health:(Some (health ~auth_mode:"prod" ()))
  in
  status_eq "missing private_reachability Fail" true
    (r.status = Relay_doctor.Fail)

let test_transport_prod_http_fail () =
  let r =
    Relay_doctor.check_transport_security ~url:"http://127.0.0.1:1"
      ~health:(Some (health ~auth_mode:"prod" ()))
  in
  status_eq "prod plaintext Fail" true (r.status = Relay_doctor.Fail)

let test_transport_prod_https_pass () =
  let r =
    Relay_doctor.check_transport_security ~url:"https://relay.example"
      ~health:(Some (health ~auth_mode:"prod" ()))
  in
  status_eq "prod https Pass" true (r.status = Relay_doctor.Pass)

let test_transport_dev_http_inconclusive () =
  let r =
    Relay_doctor.check_transport_security ~url:"http://127.0.0.1:1"
      ~health:(Some (health ~auth_mode:"dev" ()))
  in
  status_eq "dev plaintext Inconclusive" true
    (r.status = Relay_doctor.Inconclusive)

let () =
  Alcotest.run "relay_doctor_private_reachability"
    [ ( "B266 doctor checks",
        [ test_case "auth_mode prod Pass" `Quick test_auth_mode_prod_pass;
          test_case "auth_mode dev Fail" `Quick test_auth_mode_dev_fail;
          test_case "contact_protocol missing Fail" `Quick
            test_contact_protocol_missing_fail;
          test_case "contact_protocol 1 Pass" `Quick test_contact_protocol_ok;
          test_case "private_reachability prod Pass" `Quick
            test_private_reachability_prod_pass;
          test_case "private_reachability dev Inconclusive" `Quick
            test_private_reachability_dev_inconclusive;
          test_case "private_reachability missing Fail" `Quick
            test_private_reachability_missing_fail;
          test_case "transport prod http Fail" `Quick
            test_transport_prod_http_fail;
          test_case "transport prod https Pass" `Quick
            test_transport_prod_https_pass;
          test_case "transport dev http Inconclusive" `Quick
            test_transport_dev_http_inconclusive;
        ] ) ]
