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

## PufferLib training

Training runs the compiled Nim simulation directly and uses PyTorch for neural
inference and PufferLib PPO. It does not run the learned policy through BASIC.
The simulation rules and official scores stay unchanged.

Use a Python environment with the dependencies in `training/requirements.txt`.
PufferLib's native advantage extension must be built against the installed
Torch version. See [training setup](docs/training.md) for the tested versions.
After installing the Nim dependencies above, run from this repository:

```sh
sh tools/build_training.sh
python tools/train_safa.py --seconds 600 --output out/safa-train
```

This trains Safa's CNN/LSTM from scratch with the active FourScore curriculum:
per-team generalist and idle roles, individual reward shaping, random idle
actions, and idle-agent loss masking. CPU is the default. `--device cuda`
selects GPU learning on a compatible machine. GPU execution has not been
validated here.

Use a new output directory for each run. It contains initial weights, final
model and optimizer checkpoints, metrics, source snapshots, and `summary.json`.
Training stops at the first of `--seconds` or `--steps`, after finishing the
current update. `--checkpoint PATH` loads weights with a fresh optimizer, not
an exact training resume.

Evaluate the checkpoint path recorded in `summary.json` against `base.bas`:

```sh
python tools/evaluate_safa_training.py PATH_TO_MODEL.pt \
  --output out/safa-train/evaluation.json
```

Evaluation plays four full games with eight neural cogs against 24 baseline
cogs, rotating the neural team through the corners. Evaluate `initial.pt` with
the same settings to compare before and after training.

A smaller MLP baseline is also available:

```sh
python tools/train_puffer.py --seconds 600 --evaluate --output out/puffer-train
```

The 10-minute CPU curriculum test completed 663,552 agent steps and 648 PPO
updates. It scored zero in all four held-out games, so it did not demonstrate
useful learned play. See [curriculum details and results](docs/safa-curriculum.md)
and [Safa's training notes](docs/safa-training-research.md) for the source recipe
and the port's observation differences.

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
