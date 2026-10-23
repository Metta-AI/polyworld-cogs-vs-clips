# Poly World CVC

A standalone Nim Cogs vs Clips game with a fixed Machina 1 ruleset, eight
cooperative Cogs, seeded 88 by 88 maps, and 10,000-tick matches. The simulation
uses integer state and Poly World action tapes. Native and browser clients
share the same simulation and copied CoGames 2D sprites.

## Run

With the sibling dependencies already installed in `/Users/me/p`:

```sh
./tools/build_native.sh
./out/cvc --seed 1
./out/cvc-headless --seed 1 --record out/match.replay
./out/cvc --replay out/match.replay
```

Run commands from this repository. For an independent checkout, install
Nim 2.2.10 or newer, then fetch the revisions in `dependencies.lock`:

```sh
python3 tools/setup_dependencies.py
export POLYWORLD_DEPS="$PWD/.deps"
./tools/build_native.sh
```

The setup script uses its own dependency directory and leaves sibling
repositories alone. Emscripten is required for the browser build:

```sh
./tools/build_browser.sh
python3 -m http.server 8128 --bind 127.0.0.1 --directory out/browser
```

Open `http://127.0.0.1:8128`. Add `?seed=42` to select a map.

## Play and inspect

- Click a Cog or roster entry to select it, and a station to inspect it.
- Scroll to zoom, right-drag to pan, or click the minimap to navigate.
- Click Control to take over the selected Cog. Use WASD or arrow keys.
- Move into stations to gather, deposit, equip, obtain hearts, or capture.
- Space pauses and the period key advances one tick.
- Save replay writes a file on native and downloads it in the browser.
- Watch tape switches the current recording to read-only playback.
- Click the timeline to seek in playback. Drop a replay onto the client to load it.

One simulation tick is a grid turn. Display interpolation, camera movement,
and playback speed never change simulation results.

## Policies

`--bot players/base.bas` supplies a BASIC program to eight independent policy
runtimes. Programs can use `self(0)` to specialize by seat. See
[the policy interface](docs/policies.md) for observation and action functions.
The bundled baseline is intentionally simple and uses remembered local vision.

## Validation

```sh
./tools/verify.sh
nim r -d:release tests/bench_matches.nim
```

Verification checks rules, replay corruption and seeking, native to WebAssembly
replay compatibility, and every tick hash across three complete native and
WebAssembly matches. The browser and native builds do not need Python at runtime.

## Rules and provenance

See [the fixed rules](docs/rules.md) and [asset provenance](docs/provenance.md).
This is a standalone adaptation, not a drop-in MettaGrid replacement. Its compact
map generator and deterministic resolution order define a new replay version.
It does not reproduce original Python map seeds, policies, or replay files.
