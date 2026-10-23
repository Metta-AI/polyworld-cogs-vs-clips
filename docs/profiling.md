# Native profiling

Press F2 to start a Fluffy trace. Press F2 again to write
`out/profile.json` and launch the sibling Fluffy checkout with `nim r`.
Captures are limited to 10,000 events. Closing the game also saves an active
capture. Profiling starts and stops outside measured frame scopes.

For a repeatable live simulation capture:

```sh
nim r -d:release -d:CvcTracePath=out/profile.json src/cvc.nim --seed:1 --bots:players/base.bas:8
```

This advances exactly one tick per rendered frame, warms up for 1,000 frames,
captures 100 frames, prints the final simulation hash, and exits.
Override the budgets with `-d:CvcTraceWarmup=1000` and
`-d:CvcTraceFrames=100`. Use identical budgets and arguments for comparisons.
These defines are separate from Silky's UI-pass profiling controls.

Open a saved trace:

```sh
cd ../fluffy
nim r -d:release src/fluffy.nim ../polyworld-cogs-vs-clips/out/profile.json
```

## Pipe cache comparison

Native release build, seed 1, eight baseline bots, ticks 1001 through 1100,
default 1440 by 960 window. Totals across 100 frames:

| Measurement | Before | After |
| --- | ---: | ---: |
| Pipe updates | 6460.7 ms | 67.8 ms |
| Simulation and presentation step | 6483.9 ms | 89.2 ms |
| Frame including buffer swap | 6682.8 ms | 881.0 ms |
| Pipe draw-cache preparation | 14.0 ms | 0.14 ms |

Both runs ended at tick 1100 with state hash 1386605982.
Frame timings include display synchronization and are not pure CPU timings.
A changed network can still cause a route-search spike.

Settled networks are reused only when obstacle membership and the full ordered
junction inputs match. A network settles when a routing pass leaves its exact
edge paths unchanged. Changed networks keep their original incremental updates.
Draw commands are rebuilt when the edge geometry or junction inputs change.

The regression test compares every cached and uncached route over 1,120
steps, including changed walls, ownership, depleted extractors, and reset:

```sh
nim r -d:release -d:testPipes tests/test_pipes.nim
```

## Headless matches

The same capture defines work with the headless client:

```sh
nim r -d:release -d:headless -d:CvcTracePath=out/headless-trace.json src/cvc.nim --bots:players/base.bas:8 --record:out/headless-match.replay
```

The headless client finishes the entire match. It records the trace only for
the configured tick window (by default ticks 1001 through 1100), so the event
cap does not truncate a full-match capture. Override `CvcTraceWarmup` to inspect
a different stage. Trace durations exclude compilation and replay-file writing.

A release run with seed 1 and eight baseline bots takes approximately 2.5
seconds for 10,000 ticks including startup and replay writing on the development
machine. The 100-tick sample contains 2,600 events:

| Procedure | Total | Calls |
| --- | ---: | ---: |
| Bot decisions | 14.793 ms | 100 |
| Baseline policy, nested within decisions | 13.189 ms | 800 |
| Route search, nested within baseline | 8.147 ms | 800 |
| Bot memory, nested within decisions | 1.455 ms | 800 |
| Simulation advance, hashing, and recording | 2.363 ms | 100 |

Nested totals overlap. Bot decisions account for about 86% of sampled tick
work. Timed and profiled runs produce byte-identical action replays and end
with hash 1051140080.

To inspect the trace:

```sh
cd ../fluffy
nim r -d:release src/fluffy.nim ../polyworld-cogs-vs-clips/out/headless-trace.json
```
