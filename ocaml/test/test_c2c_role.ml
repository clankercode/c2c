let () =
  let role = C2c_role.parse_string {|
---
description: Test role
role: subagent
c2c:
  auto_join_rooms: [swarm-lounge, dev-room]
claude:
  tools: [Read, Bash, Edit]
---

You are a test.
|} in
  Printf.printf "description: %S\n" role.C2c_role.description;
  Printf.printf "role: %S\n" role.C2c_role.role;
  Printf.printf "c2c_auto_join_rooms: %d items\n" (List.length role.C2c_role.c2c_auto_join_rooms);
  (match role.C2c_role.c2c_auto_join_rooms with
   | [] -> Printf.printf "  (empty)\n"
   | items -> List.iter (Printf.printf "  %S\n") items);
  Printf.printf "claude: %d items\n" (List.length role.C2c_role.claude);
  (match role.C2c_role.claude with
   | [] -> Printf.printf "  (empty)\n"
   | items -> List.iter (fun (k,v) -> Printf.printf "  %S=%S\n" k v) items);
  let rendered = C2c_role.OpenCode_renderer.render role in
  Printf.printf "OpenCode output:\n%s\n" rendered
