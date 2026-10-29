# BASIC policy interface

Each Cog has an independent bounded runtime. Its program restarts each tick,
reads the same pre-tick world as the other seats, and queues one action. The
last `act` call wins. Failure stops that policy and leaves its seat resting.
The console reports the error. Replays contain actions, not policy source.

| Function | Meaning |
| --- | --- |
| `self(field)` | 0 seat, 1 tick, 2 x, 3 y, 4 role, 5 HP, 6 energy, 7 hearts, 8 team |
| `bank(element)` | Own team bank amount |
| `cargo(element)` | Own carried amount |
| `tile(x,y)` | -1 unseen, 0 floor, 1 wall, 2 hub, 3 junction, 4 ship, 5 extractor, 6 gear |
| `owner(x,y)` | -1 unseen, 0 neutral, 1 red, 2 blue, 3 green, 4 yellow |
| `station(x,y,field)` | -1 absent or unseen; fields 0 kind, 1 owner, 2 element, 3 stock, 4 role |
| `cog(seat,field)` | -1 unseen or invalid; fields 0 x, 1 y, 2 role, 3 HP, 4 team |
| `act(action)` | 0 rest, 1 north, 2 east, 3 south, 4 west |
| `baseline()` | Action from a local-vision baseline with per-seat memory |

Elements are 0 carbon, 1 oxygen, 2 germanium, 3 silicon. Roles are 0 ungeared,
1 miner, 2 aligner, 3 scrambler, 4 scout. Station kinds are 0 hub, 1 junction,
2 ship, 3 extractor, 4 gear. Coordinates are zero-based.

Spatial observation is a 13 by 13 square centered on the acting Cog. Shared
inventory is shared within each team. The baseline remembers observations and knows the fixed
compound layout. It does not read unseen station state or distant Cog positions.
Its memory is bounded by map size. `baseline()` is charged for bounded pathfinding
work, and each decision has instruction and work limits.

A minimal policy:

```basic
act(baseline())
```

A policy that always rests:

```basic
act(0)
```

The baseline handles visible Cogs separately from terrain pathfinding. It keeps
following a bounded local detour until it rejoins the main route, checking each
step for new occupants. A changed goal, failed move, or blocked detour discards
the old plan. If no local route is available, it waits and retries. Moving Cogs
do not invalidate the terrain JPS+ cache. Custom policies issuing `act` directly
must handle other Cogs themselves; the simulation does not reroute actions.

The baseline yields with a 50% coin flip when another Cog blocks its terrain
route, or when it proposes a movement destination from either of its previous
two decisions. Each seat uses a deterministic coin keyed by match seed, tick,
and seat, without consuming simulation randomness. Station interactions and
explicit custom-policy `act` calls are unchanged.

## Tensor policies

Upload raw BASIC or a ZIP with exactly one `.bas` entry and resource files.
`tensors.json` names float32, fixed or integer tensor slices. BASIC owns the
network architecture and recurrent state. Generic tensor operations include
dense layers, convolution, group normalization, activations and slicing.
`observationTensor(role, output)` writes the visible reconstructed 134-feature
CHW view into an existing `[134,13,13]` float32 tensor. Roles 0..9 are explicit
source reward roles; 3 is the generalist and 10 selects a fixed mixed lineup.
`randomInt(bound)` draws from a policy-local RNG. Existing direct queries do
not build the dense observation unless requested. Tensor math is bounded by
the same per-tick work and memory limits as other policy operations.
