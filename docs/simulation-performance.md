# Simulation performance

Measured on macOS arm64, 2026-10-23, with Nim 2.2.10 and `-d:release`.
The fixed seed-1 FourScore fixture contains 10,000 ticks and 32 Cogs.
Actions are loaded before timing. Map generation, bots, graphics, replay
hashing, compilation and file I/O are excluded. Runs were sequential,
with the Fluffy viewer closed and no concurrent builds.

| Implementation | Median seconds | Range | Ticks/second |
| --- | ---: | ---: | ---: |
| C++ without observations, fresh run | 0.291250 | 0.290379 to 0.295891 | 34,335 |
| Nim before optimization, fresh run | 0.362842 | 0.357377 to 0.363910 | 27,560 |
| Nim after optimization | 0.115809 | 0.114402 to 0.116437 | 86,349 |

Nim uses five measured runs after one complete warmup match. C++ uses
three runs after its existing 1,000-tick warmup. The optimized simulation
is 3.13 times faster than the fresh Nim baseline and 2.51 times faster
than the fresh C++ result. Relative to the earlier 0.529-second Nim
measurement it is 4.57 times faster, but the fresh comparison better
controls for machine conditions. The old C++ result was 0.362 seconds.

This compares implementations, not languages. C++ retains its configurable
rules and rewards, and its timing includes Python action-buffer assignment
and one extension call per tick. The engines receive the same actions and
map but their adapted rules produce different trajectories. These results
do not measure end-to-end BASIC bot match speed.

## Fluffy findings and changes

Following `/Users/me/p/aistuff/FLUFFY.md`, the simulation has opt-in
`-d:cvcSimTrace` instrumentation. Normal simulation builds compile these
hooks away. The capture covers ticks 9001 through 9100 of the same fixture,
well into the match when many junctions have owners.

| Inclusive trace time | Before | After |
| --- | ---: | ---: |
| 100 simulation ticks | 3.978 ms | 1.689 ms |
| Territory computation | 3.624 ms, 3,200 calls | 1.217 ms, 100 batches |
| 3,200 actions | 0.162 ms | 0.234 ms |
| 2 reconnections, nested within actions | 0.075 ms | 0.105 ms |

Territory consumed 91% of the original sampled tick duration. The change:

- Precomputes all 400 possible fixed-point radial distances at compile time,
  using the original integer square-root function exactly.
- Computes territory for all 32 Cogs in one station pass after actions.
  Station eligibility and coordinate division are no longer repeated for
  each Cog. Temporary influence arrays are bounded and stack allocated.
- Preserves the scalar territory API for clients and policies, with the same
  distance lookup.

There is no mutable territory cache and no new authoritative state.
Captures and disruptions affect the same tick. Tie handling, action order,
integer math, healing, energy, scores and RNG use are unchanged.

Tire tracks, rendered pipe connections and terrain rendering already live
in the client and were absent from the headless tick loop. The gameplay
`linked` and `reconnect` rules remain necessary simulation work.
`-d:headless` excludes the graphical client from the executable entirely.

Trace captures contain 6,502 and 3,402 events, below Fluffy's 10,000-event
limit. Tracing adds overhead and the number of hooks changed, so use the
uninstrumented full-match table for speedup claims. Nested spans overlap.
The trace was successfully loaded in the native Fluffy viewer; aggregate
timings above were also calculated directly from its JSON events.

## Verification

- All 10,000 authoritative tick hashes match the pre-change implementation,
  on both native and WebAssembly builds. Final hash: `3548051309`.
- The original recorded replay plays through with the same final hash.
- Every tile's scalar territory and batched Cog health effects match the
  original calculation for three seeds with mixed station ownership.
- Neutral territory and equal-strength ties remain neutral.
- The specific equivalent pre-optimization content hash is accepted;
  unknown rule hashes remain rejected. This is needed because replay
  content hashes include simulation source text.
- Native GUI and headless compile checks, the profiling compile check,
  `tests/tests.nim` and `tests/test_territories.nim` pass.

## Reproduction

Use the existing `out/engine-actions.csv` from the original benchmark.
See [engine-benchmark.md](engine-benchmark.md) for fixture generation and
C++ build details. Run from the repository root:

```sh
nim check experiments/bench_steps.nim
nim c -d:release -o:out/bench-steps experiments/bench_steps.nim
out/bench-steps

nim check -d:cvcSimTrace experiments/bench_steps.nim
nim r -d:release -d:cvcSimTrace experiments/bench_steps.nim out/sim-after.json

# Run the viewer from its own asset directory.
cd ../fluffy
nim r -d:release -o:../polyworld-cogs-vs-clips/out/fluffy src/fluffy.nim ../polyworld-cogs-vs-clips/out/sim-after.json
```

Passing a filename to the uninstrumented benchmark writes every tick hash
in an additional, untimed pass. `experiments/check_steps.nim` compares
against `out/steps-before.hashes`, captured before changing the simulation.
It embeds that file and the action CSV, allowing the same check in WASM:

```sh
nim r -d:release experiments/check_steps.nim
nim c -d:release -d:headless -d:emscripten --threads:off --nimcache:out/cache-perf-conformance -o:out/check_steps.cjs experiments/check_steps.nim
node out/check_steps.cjs
```

Raw local artifacts: `out/perf-before.csv`, `out/perf-after.csv`,
`out/bench-cpp-without-obs.json`, `out/sim-before.json`, and
`out/sim-after.json`. The benchmark fixture is intentionally independent
of replay source hashes, so performance-only source edits do not require
regenerating bot decisions.
