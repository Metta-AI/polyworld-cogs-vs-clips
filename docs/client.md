# Live client

The renderer reads `Session.world` directly. Simulation ticks use the same
integer rules and action frames on native and WebAssembly. Drawing, camera
motion, interpolation, and GPU caches do not mutate simulation state.

The original MettaScope terrain, sprites, team masks, pipe routing, minimap,
background shaders, and themed panel artwork are copied into this repository.
The fixed game's control meanings are:

- Transport icons: start, back one tick, play/pause, forward one tick, latest
  recorded tick, repeat. The metal scrubber seeks through recorded actions.
- Turtle through rabbit: 1, 5, 10, 50, 100, or 1000 times playback speed,
  bounded by the client's per-frame tick budget.
- Grid, eye, cloud: grid and Cog labels, current vision, explored territory.
- Move: keyboard control of the selected Cog during live simulation.
- Queue icon or M: switch the main view to original minimap pips.
- Repeat: loop the completed action tape, enabled by default. Turn it off to
  pause at the final tick. Manual stepping and seeking stay paused.
- Role icons: select and follow a matching Cog in this fixed game's crew.
- Sound icon: muted indicator. This port currently has no audio playback.

Click a Cog to inspect it. Escape clears selection. Right-drag pans, the wheel
zooms, and clicking the minimap moves the camera. F toggles following the selected
Cog. Space toggles play, period steps, and F5 saves the action tape. WASD or arrow
keys drive the selected Cog while control is enabled.

Replay seeking prepares snapshots every 5% of the timeline in small background
batches. Dragging previews the nearest snapshot; release seeks to the exact
tick from the preceding snapshot. A progress label appears while the index is
being prepared. Seeks wait for their checkpoint, following the latest drag
position. Snapshots
include simulation state, explored fog, tire tracks, and pipe history.

Seeking reconstructs the current world from lockstep actions. A live match can
continue recording when it reaches its recorded frontier. Dropped action tapes
remain playback-only. Gameplay version 3 uses the fixed FourScore map and 32 seats. Older tapes
are rejected because they describe a different game.

Comparison screenshots are under `docs/comparison`. The reference viewer has
four teams, as does this fixed game. The score and bank panels show all four
teams in red, blue, green, yellow order.

## Native command line

Run from the repository root:

```sh
nim r -d:release src/cvc.nim --bots:players/base.bas:32
nim r -d:release src/cvc.nim --bots:players/base.bas:32 --record:match.replay
nim r -d:release src/cvc.nim --replay:match.replay --play:false --speed:5
```

`--bot` and `--bots` are aliases. Repeat them to fill different slots, for example
`--bots:players/base.bas:16 --bots:players/custom.bas:16`. Counts must total 32.
Without bot arguments, every Cog uses the bundled baseline. Replay input cannot
be combined with bot arguments. Space and equals forms also work, including
`--replay match.replay` and `--record=match.replay`.

Slots 0-7 are red, 8-15 blue, 16-23 green, and 24-31 yellow.

Selecting a Cog shows its tire tracks from the last 200 ticks. Tracks use the
original straight and corner sprites and fade with simulation time. Pausing
preserves them, and replay seeking restores them from visual snapshots.

The film-camera toggle beside sound controls the director camera, enabled
by default alongside Repeat. It follows
cogs at a close zoom, prioritizing the playable area that changes territory
owner. A network cut includes the area lost around every disconnected
junction, including land becoming neutral. Simultaneous events are measured
in tick order on private station copies. Small captures can rank below
mining and deliveries. Approaching aligners and scramblers provide a weaker
fallback signal. Shots last at least
four seconds and switch when another cog has more useful activity. Manual
panning, zooming, selection, and following disable the director. Seeking
clears its history. Camera scoring reads simulation feedback only and never
changes the simulation, policies, or replay tape.
