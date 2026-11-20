# City-Builder (Godot)

- Engine: Godot 4.7.2 (Forward Plus renderer, Jolt Physics, Vulkan). Use Godot 4.x GDScript syntax, never 3.x.
- Project folder: `E:\Godot\Projects\City-Builder`
- Godot executable: `E:\Godot\Godot_v4.7.2-stable_win64.exe`
  - This is the GUI build, so it doesn't print to the terminal. Use `--log-file` to capture output.
  - `E:\Godot\Godot_v4.7.2-stable_win64_console.exe` is the console build, which prints to the terminal.
- Window: borderless fullscreen (`window/size/mode=3`) with a 1920×1080 base size; `canvas_items` stretch scales the UI to the screen.
- Main scene: `res://scenes/main.tscn`, a flat 2 km × 2 km grass plain (centered on the origin, ground at y=0) with a sun, sky and an RTS camera (`scripts/camera_rig.gd`: WASD/arrows pan, wheel zoom, middle mouse rotate).

## Road system (`scripts/roads/`)

Node/segment graph with lane-level connections (Cities: Skylines style). Traffic drives on the right.

- `road_type.gd`: `RoadType` cross-sections: 3 m lanes, listed left to right along the segment direction, centered on the curve. Lane `offset` > 0 = right of the segment direction; `forward` = runs start → end node. Presets (toolbar): `two_way`, `one_way`, `four_lane` (2 + 2), `one_way_2`. `RoadType.from_layout(forwards)` returns the one shared type per lane layout (presets included), so types compare with `==`. `reversed_layout()` = the same road seen from the other end; `is_reversible()` is false for symmetric layouts. Up to `MAX_LANES` = 8.
- `road_curve.gd`: `RoadCurve`, an immutable cubic Bezier with arc-length table, split, closest point and intersections.
- `road_network.gd`: `RoadNetwork`, which owns nodes/segments and builds meshes. `build_road()` creates nodes, splits segments where a road ends on or crosses them, and trims segment ends at junctions (`_compute_trims`) then fills a rounded junction polygon (`_junction_shape`). At tight angles where a short segment can't be trimmed back far enough, the polygon follows both edges to where they cross, so the gore stays paved.
  - Lane keys: `(segment_id << 6) | lane_index`. `get_connections(node)` returns incoming key → outgoing keys: custom per incoming lane (`custom_connections`) or defaults (`_default_outs`: all other roads except turns sharper than `MAX_DEFAULT_TURN` = 135°, unless that's the only way on; U-turn only at dead ends). Roads are ordered from sharpest right to sharpest left turn and a road's incoming lanes split them proportionally (right lanes turn right, left lanes left, each lane at least one road); lanes into the same road keep their order. A single incoming lane gets every road and lane. Custom entries are remapped on segment splits and dropped for a segment whose lanes change (type change/reverse/removal).
  - `connection_curve()` gives the path through a junction, intended for future vehicles.
  - Lane snapping: a one-lane road can attach to a node or segment at the road center or at a lane center of a wider road (closest to the mouse). It stays connected to the same node; the segment stores `start_offset`/`end_offset` (end point relative to node), and junction trimming and sorting use these offsets. Multi-lane types reset offsets to 0 on upgrade.
  - Lane direction mismatch: lanes of different segments that meet at the same spot (< 0.5 m) but travel in opposite directions set `RoadNode.lane_mismatch` and show a billboard icon (`icons/lane_mismatch.svg`). It's allowed, only flagged. `build_road(curve, type, start, end)` takes end dictionaries `{node, on_segment, anchor}`.
  - Lane editing: `edit_lanes(segment, LaneEdit.ADD_LEFT/ADD_RIGHT/REMOVE/REVERSE, lane, EditScope)`. Added and kept lanes stay in place: the center line moves (via `start_offset`/`end_offset`) so the road widens or narrows on the edited side; removing a middle lane closes the gap from both sides. `EditScope`: SEGMENT, ROAD (through nodes with exactly 2 roads), STREET (also straight on through junctions, < 30°). `lane_edit_reach()` lists the segments reached (only those with the same layout seen the same way); segments drawn the other way get the mirrored edit.
- `road_tool.gd`: `RoadTool` input modes (straight/curved/freeform drawing, upgrade/reverse, lane layout, lane connections, node, bulldoze), snapping (nodes, segments, soft 15° / 8 m grid) and previews.
  - Toolbar "Lanes" = `Mode.LAYOUT`: click a lane to reverse it, right click to remove it, click beside a road to add a lane; default scope ROAD, Shift = STREET, Alt = SEGMENT; Ctrl+click picks the road's layout for drawing/upgrading (`road_type_changed`; the toolbar shows it as an extra type button). Toolbar "Connections" = `Mode.LANES` (lane connection editor).
- `road_overlay.gd` (lane debug view), `tri_batch.gd` (gizmo triangles), `road_mesh_builder.gd`, `scripts/ui/road_toolbar.gd` (UI built in code, forced LTR).

### Node Controller (junction shaping)

- Per road end, `RoadSegment.start_settings`/`end_settings` (`EndSettings`): `offset` (m added to the automatic trim), `shift` (m sideways; stored in `start_offset`/`end_offset`, which also hold lane snapping), `rotate` (degrees, slants the end edge via `skew_start`/`skew_end`), `stretch` (width fraction, tapers over 15 m) and `radius` (curb radius of the corner on the end's right side, < 0 = automatic). Sides are seen looking outward from the node: positive = right.
- A custom curb is a circular arc and pushes both adjacent road ends back so it fits (`_fillet_tangent`); automatic corners keep the old Bezier rounding.
- `RoadNode.mode` (`NodeMode`): AUTO, MIDDLE (2 roads meet untrimmed, no junction surface), STRETCH (2 roads, ≥ 12 m transition), UTURN (default connections include U-turns). MIDDLE/STRETCH act as AUTO unless the node has exactly 2 roads (`effective_mode`).
- Lanes end on the slanted edges (`_lane_end_distance`) and follow stretch, so traffic paths through the junction follow the edited shape.
- Settings survive splits (the far piece keeps them), type changes (shift is re-applied) and reversing; new ends start at defaults; a removed road's settings go with it.
- Traffic lights: `RoadNode.traffic_lights`, toggled with `set_traffic_lights`; `has_traffic_lights` is true only at junctions of ≥ `MIN_LIGHT_ROADS` = 3 roads. Copy/paste carries the flag, reset leaves it.
- API: `get_end_settings`/`set_end_settings`, `set_node_mode`, `reset_node`, `copy_node_settings`/`paste_node_settings` (matched by order around the node), `node_end_info` (handle positions), `align_corner` (moves a corner onto a point; holds a target corner of the same node in place).
- UI: Node tool in `road_tool.gd` (drag blue = offset / Shift+drag = shift, yellow corners = angle, green = curb radius, A = align, T = traffic lights, Ctrl+C/V, R) and `scripts/ui/node_panel.gd` (`NodePanel`, traffic lights checkbox, sliders per road end).

## Traffic (`scripts/traffic/`)

- Outside connections: dead-end nodes on the map border (within 3 m of ±`map_half_size`). The road tool snaps ends within 8 m of the edge onto it. Each lane leaving one spawns cars (slider: cars/min per entry lane) that route to a random other outside connection reachable from that lane (lane changes included). No connections are built at outside connections (no U-turns at the map edge).
- `traffic_graph.gd`: `TrafficGraph`, rebuilt from the network on every `changed`. It has lane pieces and junction connection pieces (polylines with per-point curve speed limits from `LATERAL_ACCEL` = 7 m/s²), Dijkstra routing with a cache, and conflict zones: for each pair of paths through a junction that come within `ZONE_DISTANCE` (2.8 m) of each other, cross, share an exit lane or split from the same entry lane, the stretch of each path involved (`Piece.zones`, sorted by start; `conflicts` lists the other pieces). Neighboring same-direction lane pieces of a segment are linked in `Piece.beside` as lane-change edges (`LANE_CHANGE_COST` = 40 m), so a route may contain two consecutive lane pieces of one segment (`is_lane_change(a, b)`), meaning "change lanes along this segment". Routes are shared with the cache: duplicate a `PackedInt32Array` route before mutating it (packed arrays are passed by reference).
- `traffic_manager.gd`: `TrafficManager`. Cars use IDM car following (up to 70 km/h, each car's own preferred speed 80–100 % of that, 5 m/s² accel, 6 m/s² comfortable braking, 18 m/s² max braking, 1.2 s headway) plus anticipatory braking for curves and junctions ahead.
  - Junctions: within 35 m a car queues for every conflict zone on its path (`_request`), commits to entering only if the exit lane has room, then reserves zones in order along the path (`_junction_stop`). A zone side is free if nobody holds the other side and nobody who asked earlier is queued for it, so waits always point to earlier cars and can't form a circle. The car drives up to just before the first zone it can't reserve and waits there, inside the junction if that's where it is (e.g. a left turn waiting at the oncoming lane). Until everything is reserved it approaches its stop point at ≤ 35 km/h and ignores cars beyond it (only once it has asked for the junction; before that, cars waiting inside the junction count as leaders so they don't appear suddenly). A zone is released once the car's tail has passed it.
  - Cars also follow a car that turned off their lane onto another path while its tail is still in the lane.
  - Lane changes (`_update_lane_change`): a route step into the lane beside is done as soon as there is a safe gap (`_change_safe`: neither the car nor its new follower brakes harder than 3 m/s², ≥ 2.5 m clear; followers include cars about to enter the lane from the junction behind) and the car's tail is clear of the junction behind. Changes should finish before the junction request point (`_change_deadline`: lane length − 35 m, 30 m more per further change; on short lanes anywhere before the end). A car that hasn't found a gap waits before that point (the lookahead stops there, so it doesn't request the junction yet); after 10 s stopped it gives up and takes another way (`_give_up_change`, to another destination if needed). The car switches pieces at once (the lane piece it left is removed from its route) and slides over for `LANE_CHANGE_TIME` = 2.5 s in `car_pose`; meanwhile a ghost `Car` (not in `cars`) keeps its spot in the old lane so followers there still see it, and the car also follows the old lane's leader.
  - Overtaking (`_try_overtake`, MOBIL-style, every 0.5 s): a car held up by a leader moves to the lane beside if it gains ≥ 0.6 m/s² (minus 0.3 × the new follower's braking), only well before the junction and only into a lane whose route goes onto the same road without changing back.
  - Counters: `lane_changes`, `overtakes`, `lane_change_give_ups`.
  - Traffic lights: `TrafficGraph.lights` (node id → phase count and the `node_end_info` of each road bringing traffic in, in phase order); incoming lane pieces and the junction paths from them carry `light_node`/`light_phase`. Each road in turn gets green (`LIGHT_GREEN` 15 s, `LIGHT_YELLOW` 3 s, then `LIGHT_ALL_RED` 2 s for everyone); `light_state(node, phase)`. When the light turns yellow or red, an approaching car decides once (`_must_stop_at_light`, kept in `light_k`/`light_go`) whether it can stop with ≤ comfortable braking. If so it gives up any junction queue place, reservations and commitment (`_withdraw`) and stops with its front `RED_STOP_DISTANCE` = 1.5 m before the junction, using `_stop_accel` (brakes evenly for the exact rest point; plain IDM creeps past its minimum gap), and ignores cars beyond. Otherwise it goes through. On green it uses the normal zone reservation (cars still clearing the junction keep their zones). Cars stopped at red don't queue for zones, so they can't block the green road. Drawn by the manager: white stop lines, and a pole with red/yellow/green lamps at the right curb of each incoming road (`_build_lights`, lamp colors updated in `_update_visuals`).
  - On network changes, cars are projected onto the new graph and re-routed, or removed.
- `step(delta)` drives the simulation (called from `_physics_process`) and works without the scene tree, so tests call it directly.
- An unsignalized 4-way carries roughly 30 cars/min. Higher demand queues back to the entries, where spawning waits.

## Tests

- `tests/test_roads.gd`: headless network tests. Run with `-s res://tests/test_roads.gd` (add `--headless --path ... --log-file ...` as above). It prints `ROAD TESTS: PASS` and exits 0. Run `--import` first after adding new `class_name` scripts.
- `tests/test_traffic.gd`: headless traffic tests on a 400 m map (trips complete, no car overlaps via an oriented-box check, speed/accel limits, no emergency braking, bends slow cars, one-way direction, network edits while driving, a crossing edited with the Node Controller, multi-lane roads with an edited piece, lane changes to reach destinations the spawn lane doesn't lead to, overtaking on a two-lane one-way, traffic lights switched on mid-run: nobody enters on red, cars stop at the line). Prints `TRAFFIC TESTS: PASS`. Takes about 20 s.
- `tests/demo_roads.gd`: sample network with the overlay and lane tool on, for rendered frames.
- `tests/demo_node_controller.gd`: junctions shaped with the Node Controller and the Node tool open. Pass `-- close` for a zoomed-in view with the lane overlay.
- `tests/demo_lanes.gd`: a four-lane crossing with edited lane layouts, the lane overlay and the Lanes tool on.
- `tests/demo_traffic.gd`: border-to-border roads with 150 s of pre-simulated traffic and a fixed camera, for rendered frames. Pass `-- lights` for traffic lights at the center crossing, seen closer.

## Rendering a test frame

- The project uses Vulkan on Windows (`rendering_device/driver.windows="vulkan"`) because D3D12 crashed on this machine (Intel UHD 770). Don't switch it back.
- Render frames with `--write-movie <dir>\f.png --quit-after 30` (no `--headless`). Frames come out at 1920×1080. This opens a fullscreen window, and user input in it changes the frame, so a strange camera view may just be the user moving it.

## Checking work

Import or validate the project headlessly and read the log (PowerShell):

```powershell
$log="$env:TEMP\godot_check.log"
Start-Process "E:\Godot\Godot_v4.7.2-stable_win64.exe" -ArgumentList '--headless','--path','"E:\Godot\Projects\City-Builder"','--import','--log-file',"`"$log`"" -Wait -NoNewWindow
Get-Content $log
```

To run the game or a specific scene headlessly, replace `--import` with `--quit-after 300` (plus an optional `res://path/scene.tscn`).

## Conventions

- Don't hand-edit `.godot/`, `*.import` files, or `uid=` values; let the editor regenerate them.
- Prefer typed GDScript (`var x: int`, `func f() -> void`).
