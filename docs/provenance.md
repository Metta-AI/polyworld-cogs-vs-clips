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

The client terrain adjacency table follows MettaScope's
`src/mettascope/gamemode/terrains.nim` from the same checkout. The presentation
uses the original sand, splats, station stamps, cliff and mask sheets, pipes,
starfield, portraits, resource icons, HUD panels, and theme textures.
`tools/gen_atlas.nim` generates an inverse-mask cliff overlay and crops a metal
panel frame from the original artwork. Ground and decals are drawn before this
overlay, reproducing the masked terrain composition with the shared Silky atlas.

All presentation caches are derived from the live `World`. They do not consume
simulation randomness or enter state hashes, action tapes, or gameplay rules.
The map geometry remains the standalone fixed game's geometry. Rendering does
not import MettaScope's replay loader, object-history schema, or JSON replay
format. Poly World `ActionTape` remains the only replay format.
