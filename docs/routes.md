# CVC cardinal JPS+

The default bot router is in `src/cvc/routes.nim`. It uses four-direction
jump-point search with precomputed vertical jump distances. Global routing has no
runtime BFS or ordinary A* fallback. A separate bounded local A* search
handles moving cogs without changing the global jump tables.

The pruning follows the horizontal-first JPS4 rules described by
[Johannes Baum](https://arxiv.org/html/2501.14816v1). Horizontal successors
remain adjacent cells. Vertical successors jump directly to the next forced
turn or an intervening goal. The precomputed distances eliminate vertical
scanning during a query. A priority queue orders jump successors by integer
path length plus Manhattan distance.

Each bot owns its remembered walkability and reusable search arrays. Unknown
cells stay optimistically passable. Jump tables contain terrain and station
obstacles only, with passable start and bump-interaction target exceptions.
Moving cogs never enter these tables. Terrain or interaction-endpoint changes
invalidate the affected column and its neighbors.

The bot follows the terrain route while its next step is free. When a visible
cog blocks that step, it chooses an unoccupied waypoint up to six steps ahead
on the terrain path and uses local A* to rejoin it. The local search stays in
a 13 by 13 square and expands at most 169 cells. If no local detour is found,
the bot waits and retries on the next tick. Distant cogs do not trigger local
searches. All selected movement steps avoid currently visible occupied cells.

The returned distance is the terrain distance plus any local detour cost.
It is not a globally optimal distance through all moving obstacles.

Search states distinguish horizontal, northward, and southward arrivals.
This preserves the different successors permitted by direction-dependent
pruning. Stable integer queue ordering keeps native and WebAssembly decisions
deterministic.

## Validation

- 12,000 randomized terrain queries match BFS distance and first-step legality.
  Moving-cog queries verify safe next steps, unchanged jump tables, and the
  local expansion bound.
- All 41,472 start/goal queries across the 512 three-by-three obstacle masks
  match BFS distances.
- 80,000 real queries from a full seed-1 baseline match agree with an
  independent terrain-only BFS shortest-distance oracle.
- Existing action replays remain compatible because simulation rules did
  not change.

Equal-length path tie-breaking differs from the old BFS. New bot matches can
therefore take different actions and produce different scores. The benchmark
returns the old BFS actions so that both routers see identical queries.

## Benchmark

```sh
nim r -d:release -d:benchRoutes -d:cvcBfs experiments/bench_routes.nim
```

The `cvcBfs` compile-time switch retains the old implementation for reference
benchmarks only. Normal builds use terrain JPS+ with separate local cog avoidance.

On 80,000 identical seed-1 BFS bot queries, routing took 610.9 ms before
separating moving cogs and 203.6 ms afterward, including local avoidance:
about three times faster. The new run used 3,629 local detours.
An in-run BFS comparison took 1,918.6 ms. Timing excludes the independent
oracle and shared observation update. All terrain distances were checked;
local avoidance intentionally does not promise a global crowd-aware optimum.

Three alternating full headless matches, including replay writing, had
medians of 1.71 seconds before separating cog avoidance and 1.09 seconds
afterward. These matches produce different action sequences, so the
identical-query benchmark is the direct algorithm comparison.

A Fluffy capture is available at `out/headless-avoidance-trace.json`. Reproduce it:

```sh
nim r -d:release -d:headless -d:CvcTracePath=out/headless-avoidance-trace.json src/cvc.nim --bots:players/base.bas:8 --record:out/jps-match.replay
```
