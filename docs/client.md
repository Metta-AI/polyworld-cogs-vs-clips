# Live client

The renderer reads `Session.world` directly. Simulation ticks use the same
integer rules and action frames on native and WebAssembly. Drawing, camera
motion, interpolation, and GPU caches do not mutate simulation state.

The original MettaScope terrain, sprites, team masks, pipe routing, minimap,
background shaders, and themed panel artwork are copied into this repository.
The fixed game's control meanings are:

- Transport icons: start, back one tick, play/pause, forward one tick, latest
  recorded tick. The metal scrubber seeks through recorded actions.
- Turtle through rabbit: 1, 5, 10, 50, 100, or 1000 times playback speed,
  bounded by the client's per-frame tick budget.
- Grid, eye, cloud: grid and Cog labels, current vision, explored territory.
- Move: keyboard control of the selected Cog during live simulation.
- Queue icon or M: switch the main view to original minimap pips.
- Repeat: loop the completed action tape.
- Role icons: select and follow a matching Cog in this fixed game's crew.
- Sound icon: muted indicator. This port currently has no audio playback.

Click a Cog to inspect it. Escape clears selection. Right-drag pans, the wheel
zooms, and clicking the minimap moves the camera. F toggles following the selected
Cog. Space toggles play, period steps, and F5 saves the action tape. WASD or arrow
keys drive the selected Cog while control is enabled.

Seeking reconstructs the current world from lockstep actions. A live match can
continue recording when it reaches its recorded frontier. Dropped action tapes
remain playback-only. Gameplay version 2 uses the original fixed Machina-1
map; version 1 tapes are rejected because they describe a different arena.

Comparison screenshots are under `docs/comparison`. The reference viewer has
four teams; this fixed game shows its two factions. Panel dimensions and artwork
follow the original, with row counts adapted to those two factions.
