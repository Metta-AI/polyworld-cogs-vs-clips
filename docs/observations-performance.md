# Observation performance

Measured on the local macOS arm64 host on 2026-10-26. All runs use the existing
10,000-tick action fixture, seed 1, 32 cogs, and the cropped 120 by 120 FourScore
map. Times exclude initialization, compilation, bots, rendering, file I/O and
training. Each row is a median after warmup. The C++ and final Nim timings ran
sequentially before training started.

| Workload | Seconds per match | Range | Match ticks/second |
| --- | ---: | ---: | ---: |
| Original C++ simulation with observations | 4.635 | 4.610–4.671 | 2,158 |
| Nim simulation with reference observations | 20.551 | 20.324–20.584 | 487 |
| Nim simulation with optimized observations | 0.7164 | 0.7161–0.7164 | 13,959 |
| Nim simulation alone, current build | 0.11065 | 0.10866–0.11102 | 90,377 |

The full Nim observation workload is **6.47 times faster** than the measured
original C++ workload. The optimized and reference Nim builders produce exactly
the same tokens. The C++ and Nim feature schemas are different: the port keeps
local objects and fixed global game data, while the original engine supports
configurable observation features and generic handlers. This is an application
comparison, not identical observation semantics or a language benchmark.

The reference implementation scans all stations and cogs for each observed
cell. It exists to validate the indexed implementation; it is not a copy of
the original C++ algorithm. Indexing avoids that repeated object search. The
remaining padding clear was changed from per-token stores to one contiguous
`memset` per observation after Fluffy identified its cost. No cache changes the
simulation or retains an old observation value.

## Fluffy results

Traces cover the same ticks 9001–9100 of the recorded action fixture. They contain
100 batch calls and 3,200 per-cog encoding calls. Inclusive times overlap.

| Span | Reference | Indexed | Indexed with bulk padding |
| --- | ---: | ---: | ---: |
| Observation batch, total | 204.88 ms | 7.82 ms | 6.39 ms |
| Per-cog encoding, total | 204.74 ms | 7.69 ms | 6.27 ms |
| Clear padding, total | Not separately traced | 1.744 ms | 0.279 ms |
| Occupancy preparation, total | Not used | 0.054 ms | 0.054 ms |

The initial indexed trace before adding the padding span measured 8.17 ms.
The instrumented C++ pass measured 4.337 seconds in observation construction;
profiling results are reported separately from uninstrumented match times.

Local evidence:

- `out/observations-before.json`: Fluffy reference trace.
- `out/observations-padding.json`: indexed trace before bulk clearing.
- `out/observations-after.json`: final Fluffy trace.
- `out/observations-performance.json`: raw timings and trace aggregates.
- `out/bench-cpp-with-obs.json`: repeated C++ runs and phase timings.
- `out/bench-obs.csv`: final Nim match timings.
- `out/bench-sim-training.csv`: freshly rebuilt simulation-only timings.

The unchanged authoritative final hash is `3548051309`. Observation tests cover
reference equality, mutation isolation, map edges, removed extractors, stale
padding, large HP/inventory/score values, invisible inventories, and crowded
windows. Bridge tests compare every state hash against direct simulation,
including terminal auto-reset and validation before applying a batch.

See [training.md](training.md) for build and reproduction commands.
