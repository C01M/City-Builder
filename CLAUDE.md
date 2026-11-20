# City-Builder (Godot)

- Engine: Godot 4.7.2 (Forward Plus renderer, Jolt Physics, Vulkan). Use Godot 4.x GDScript syntax, never 3.x.
- Godot executable: `C:\Users\user1\Downloads\Godot_v4.7.2-stable_win64.exe`
  - This is the GUI build, so it doesn't print to the terminal. Use `--log-file` to capture output.
- Main scene: `res://scenes/main.tscn`, a flat 2 km × 2 km grass plain (centered on the origin, ground at y=0) with a sun, sky and an RTS camera (`scripts/camera_rig.gd`: WASD/arrows pan, wheel zoom, middle mouse rotate).

## Road system (`scripts/roads/`)

Node/segment graph with lane-level connections (Cities: Skylines style). Traffic drives on the right.

- `road_type.gd`: `RoadType` cross-sections (`two_way`: 2 × 3 m lanes, `one_way`: 1 × 3 m). Lane `offset` > 0 = right of the segment direction; `forward` = runs start → end node.
- `road_curve.gd`: `RoadCurve`, an immutable cubic Bezier with arc-length table, split, closest point and intersections.
- `road_network.gd`: `RoadNetwork`, which owns nodes/segments and builds meshes. `build_road()` creates nodes, splits segments where a road ends on or crosses them, and trims segment ends at junctions (`_compute_trims`) then fills a rounded junction polygon.
  - Lane keys: `(segment_id << 6) | lane_index`. `get_connections(node)` returns incoming key → outgoing keys: custom per incoming lane (`custom_connections`) or defaults (all other roads; U-turn only at dead ends). Custom entries are remapped on segment splits and dropped for a segment whose lanes change (type change/reverse/removal).
  - `connection_curve()` gives the path through a junction, intended for future vehicles.
- `road_tool.gd`: `RoadTool` input modes (straight/curved/freeform drawing, upgrade/reverse, lanes, bulldoze), snapping (nodes, segments, soft 15° / 8 m grid) and previews.
- `road_overlay.gd` (lane debug view), `tri_batch.gd` (gizmo triangles), `road_mesh_builder.gd`, `scripts/ui/road_toolbar.gd` (UI built in code, forced LTR).

## Tests

- `tests/test_roads.gd`: headless network tests. Run with `-s res://tests/test_roads.gd` (add `--headless --path ... --log-file ...` as above). It prints `ROAD TESTS: PASS` and exits 0. Run `--import` first after adding new `class_name` scripts.
- `tests/demo_roads.gd`: sample network with the overlay and lane tool on, for rendered frames.

## Rendering a test frame

- The project uses Vulkan on Windows (`rendering_device/driver.windows="vulkan"`) because D3D12 crashed on this machine (Intel UHD 770). Don't switch it back.
- Render frames with `--write-movie <dir>\f.png --quit-after 30` (no `--headless`). This opens a window, and user input in it changes the frame, so a strange camera view may just be the user moving it.

## Checking work

Import or validate the project headlessly and read the log (PowerShell):

```powershell
$log="$env:TEMP\godot_check.log"
Start-Process "C:\Users\user1\Downloads\Godot_v4.7.2-stable_win64.exe" -ArgumentList '--headless','--path','"C:\Users\user1\Documents\city-builder"','--import','--log-file',"`"$log`"" -Wait -NoNewWindow
Get-Content $log
```

To run the game or a specific scene headlessly, replace `--import` with `--quit-after 300` (plus an optional `res://path/scene.tscn`).

## Conventions

- Don't hand-edit `.godot/`, `*.import` files, or `uid=` values; let the editor regenerate them.
- Prefer typed GDScript (`var x: int`, `func f() -> void`).
