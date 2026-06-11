let grace = 20.0
let bucket = 10.0
let step = 4
let d_max = 24
let window_s = 600.0

let cost_of_route = function
  | "register" -> 10
  | "send" | "send_all" | "send_room" | "room-send" | "room_send" -> 1
  | "poll" | "peek" | "heartbeat" -> 0
  | _ -> 0

let required_difficulty ~accumulated_cost =
  if accumulated_cost <= grace then 0
  else
    let buckets = ceil ((accumulated_cost -. grace) /. bucket) in
    min d_max (step * int_of_float buckets)

type actor_cost = {
  mutable accumulated_cost : float;
  mutable updated_at : float;
}

type t = {
  window_s : float;
  actors : (string, actor_cost) Hashtbl.t;
}

let create ?(window_s = window_s) () =
  { window_s = max 0.0 window_s; actors = Hashtbl.create 128 }

let decayed_cost t actor ~now =
  if actor.accumulated_cost <= 0.0 then 0.0
  else
    let elapsed = max 0.0 (now -. actor.updated_at) in
    if elapsed <= 0.0 then actor.accumulated_cost
    else if t.window_s <= 0.0 || elapsed >= t.window_s then 0.0
    else actor.accumulated_cost *. (1.0 -. (elapsed /. t.window_s))

let current_cost t ~actor_id ~now =
  match Hashtbl.find_opt t.actors actor_id with
  | None -> 0.0
  | Some actor -> decayed_cost t actor ~now

let required_difficulty_for_actor t ~actor_id ~now =
  current_cost t ~actor_id ~now |> fun accumulated_cost ->
  required_difficulty ~accumulated_cost

let record_cost t ~actor_id ~cost ~now =
  let base_cost = current_cost t ~actor_id ~now in
  let cost = max 0 cost |> float_of_int in
  let accumulated_cost = base_cost +. cost in
  if cost > 0.0 then
    Hashtbl.replace t.actors actor_id { accumulated_cost; updated_at = now };
  required_difficulty ~accumulated_cost

let record_route t ~actor_id ~route ~now =
  record_cost t ~actor_id ~cost:(cost_of_route route) ~now
