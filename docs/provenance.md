# Source and asset provenance

The standalone game is implemented in Nim. Its action-tape integration follows
Poly World's Heartleaf replay integration and imports the shared `tapes`,
`rngs`, `hashes`, and `policyhosts` modules. The exact engine and dependency
revisions are recorded in `dependencies.lock`.

Game rules were inspected from Metta-AI/coworld-cogs-vs-clips at
`a10896a83e2432e992ca9ac6c11a810569355fe3`. Selected Python reference files are
copied verbatim under `docs/reference`. They remain reference material with
upstream provenance and are not relicensed by the root license.

The artwork and Inter font were copied from the local Metta checkout at
`03c0f3f13719055a8810f43567fa30492e61cc22`, under
`packages/mettagrid/nim/mettascope/data`. Copied files and SHA-256 fingerprints
are recorded in `reference/assets.json`. The MettaGrid MIT license and Inter
Open Font License are included in `reference`.

`data/atlas.png` is generated from the copied sprites and font with
`nim r -d:release tools/gen_atlas.nim`. There are no runtime dependencies on
assets in the original checkout.

The client directly ports MettaScope's Nim `pixelator`, `tilemap`, `shaderquad`,
`starfield`, `terrains`, and `pipegrid` modules from the same checkout. Their
standalone counterparts are `pixelators`, `tilemaps`, `shaderquads`, `starfields`,
`grounds`, and `pipes`. The original adjacency tables, framebuffer mask passes,
sand and decal composition, selective team masks, lamp shader, pipe routing,
and minimap pips are retained. `clients.nim` uses the original gameplayer panel
assets, geometry, transport buttons, pixel font, resource cells, and timeline.

Replay-object reads are replaced with the current `World`. Terrain initializes
from the fixed map. Moving objects and counters read the current tick. Bounded
exploration and pipe caches advance with simulation ticks and reconstruct from
action frames on seeking. They never consume simulation randomness or enter
state hashes. Poly World `ActionTape` remains the only replay format.

The fixed arena was exported with `make_machina1_mission(8).make_env()` and
`MapGen(config).build_for_num_agents(8)` using seed 1 at the recorded CvC
reference revision. The five-cell outer padding is omitted. The original
88 by 88 grid is embedded in Nim from `data/maps/machina1.txt`, including all
walls, objects, and spawn locations. Gameplay version 2 records this change.

The pixel font is `pf_tempesta_five_compressed.ttf` from the same MettaScope
asset directory. `docs/reference/assets.json` records all copied asset hashes.
No generated replacement artwork is used.

FourScore uses the same reference revision's `FourScoreMission` and
`FourScoreVariant`, retained under `docs/reference`. The frozen map was exported
with `FourScoreMission().make_env().game.map_builder`, setting its seed to 1,
then `MapGen(builder).build().grid`. Removing the five-cell outer border gives
`data/maps/fourscore.txt`. Team spawns are encoded as 0-3 in corner order.
