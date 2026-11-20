# City-Builder (Godot)

- Engine: Godot 4.7.2 (Forward Plus renderer, Jolt Physics, Vulkan). Use Godot 4.x GDScript syntax, never 3.x.
- Project folder: `E:\Godot\Projects\City-Builder`
- Godot executable: `E:\Godot\Godot_v4.7.2-stable_win64.exe`
  - This is the GUI build, so it doesn't print to the terminal. Use `--log-file` to capture output.
  - `E:\Godot\Godot_v4.7.2-stable_win64_console.exe` is the console build, which prints to the terminal.
- Main scene: `res://scenes/main.tscn`, a flat 2 km × 2 km grass plain (centered on the origin, ground at y=0) with a sun, sky and an RTS camera (`scripts/camera_rig.gd`: WASD/arrows pan, wheel zoom, middle mouse rotate).

## Road system (`scripts/roads/`)

Node/segment graph with lane-level connections (Cities: Skylines style). Traffic drives on the right.

- `road_type.gd`: `RoadType` cross-sections (`two_way`: 2 × 3 m lanes, `one_way`: 1 × 3 m). Lane `offset` > 0 = right of the segment direction; `forward` = runs start → end node.
- `road_curve.gd`: `RoadCurve`, an immutable cubic Bezier with arc-length table, split, closest point and intersections.
- `road_network.gd`: `RoadNetwork`, which owns nodes/segments and builds meshes. `build_road()` creates nodes, splits segments where a road ends on or crosses them, and trims segment ends at junctions (`_compute_trims`) then fills a rounded junction polygon.
  - Lane keys: `(segment_id << 6) | lane_index`. `get_connections(node)` returns incoming key → outgoing keys: custom per incoming lane (`custom_connections`) or defaults (all other roads; U-turn only at dead ends). Custom entries are remapped on segment splits and dropped for a segment whose lanes change (type change/reverse/removal).
  - `connection_curve()` gives the path through a junction, intended for future vehicles.
  - Lane snapping: a one-lane road can attach to a node or segment at the road center or at a lane center of a wider road (closest to the mouse). It stays connected to the same node; the segment stores `start_offset`/`end_offset` (end point relative to node), and junction trimming and sorting use these offsets. Multi-lane types reset offsets to 0 on upgrade.
  - Lane direction mismatch: lanes of different segments that meet at the same spot (< 0.5 m) but travel in opposite directions set `RoadNode.lane_mismatch` and show a billboard icon (`icons/lane_mismatch.svg`). It's allowed, only flagged. `build_road(curve, type, start, end)` takes end dictionaries `{node, on_segment, anchor}`.
- `road_tool.gd`: `RoadTool` input modes (straight/curved/freeform drawing, upgrade/reverse, lanes, bulldoze), snapping (nodes, segments, soft 15° / 8 m grid) and previews.
- `road_overlay.gd` (lane debug view), `tri_batch.gd` (gizmo triangles), `road_mesh_builder.gd`, `scripts/ui/road_toolbar.gd` (UI built in code, forced LTR).

## Traffic (`scripts/traffic/`)

- Outside connections: dead-end nodes on the map border (within 3 m of ±`map_half_size`). The road tool snaps ends within 8 m of the edge onto it. Each lane leaving one spawns cars (slider: cars/min per entry lane) that route to a random other outside connection.
- `traffic_graph.gd`: `TrafficGraph`, rebuilt from the network on every `changed`. It has lane pieces and junction connection pieces (polylines with per-point curve speed limits from `LATERAL_ACCEL`), Dijkstra routing with a cache, and per-junction `conflicts` (paths that cross, come too close, share an exit lane, or diverge from the same entry lane).
- `traffic_manager.gd`: `TrafficManager`. Cars use IDM car following (70 km/h, 5 m/s² accel, 6 m/s² comfortable braking, 18 m/s² max braking, 1.2 s headway) plus anticipatory braking for curves and junctions ahead. At junctions with conflicts a car must reserve its path (first come, first served; exit lane must have room); until then it approaches at ≤ 20 km/h, asks within 35 m, and ignores cars beyond the stop line. Reservations are released once the car's tail leaves the junction. On network changes, cars are projected onto the new graph and re-routed, or removed.
- `step(delta)` drives the simulation (called from `_physics_process`) and works without the scene tree, so tests call it directly.
- An unsignalized 4-way carries roughly 20–25 cars/min, similar to an all-way stop. Higher demand queues back to the entries, where spawning waits.

## Tests

- `tests/test_roads.gd`: headless network tests. Run with `-s res://tests/test_roads.gd` (add `--headless --path ... --log-file ...` as above). It prints `ROAD TESTS: PASS` and exits 0. Run `--import` first after adding new `class_name` scripts.
- `tests/test_traffic.gd`: headless traffic tests on a 400 m map (trips complete, no car overlaps via an oriented-box check, speed/accel limits, no emergency braking, bends slow cars, one-way direction, network edits while driving). Prints `TRAFFIC TESTS: PASS`. Takes about 20 s.
- `tests/demo_roads.gd`: sample network with the overlay and lane tool on, for rendered frames.
- `tests/demo_traffic.gd`: border-to-border roads with 150 s of pre-simulated traffic and a fixed camera, for rendered frames.

## Rendering a test frame

- The project uses Vulkan on Windows (`rendering_device/driver.windows="vulkan"`) because D3D12 crashed on this machine (Intel UHD 770). Don't switch it back.
- Render frames with `--write-movie <dir>\f.png --quit-after 30` (no `--headless`). This opens a window, and user input in it changes the frame, so a strange camera view may just be the user moving it.

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
