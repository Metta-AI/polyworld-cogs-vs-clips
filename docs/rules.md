# Fixed rules

The reference is Metta-AI/coworld-cogs-vs-clips revision
`a10896a83e2432e992ca9ac6c11a810569355fe3`, specifically its FourScore mission.
Selected reference Python files are retained in `docs/reference/` for inspection.
They are not imported or executed by the game.

There are four teams of eight Cogs (red, blue, green, yellow), no Clips,
a 120 by 120 arena, and 10,000 ticks. Each team has its own bank and hearts.
The client presents 20 ticks per second. Each final score is the accumulated
number of that team's held junctions divided by 10,000.

| Rule | Fixed value |
| --- | --- |
| Elements | Carbon, oxygen, germanium, silicon |
| Initial shared elements | 24 of each |
| Initial shared hearts | 5 |
| Heart recipe | 7 of each element |
| Heart capacity | 10 |
| Gear costs, C/O/G/S | Miner 1/1/3/1, Aligner 3/1/1/1, Scrambler 1/3/1/1, Scout 1/1/1/3 |
| Health capacity | 100, Scrambler 300, Scout 500 |
| Initial health | 50 |
| Energy capacity | 20, Scout 120 |
| Movement or station use | 4 energy |
| Cargo capacity | 4, Miner 44 |
| Extraction per use | 1, Miner 10 |
| Extractor stock | 100, removed when empty |
| Day cycle | 200 ticks, 100 daylight and 100 night |
| Solar regeneration | 3 during day, 1 at night |
| Friendly healing | 100 health and energy per tick, capped |
| Health drain | 1 per tick, plus 1 in enemy territory |
| Junction territory radius | 10 |
| Hub territory radius | 20 |
| Capture reach | 15 from network, 25 from hub |

Friendly hubs and junctions accept deposits into the shared bank. An empty-handed
Cog bumping the hub withdraws one heart, or crafts one if the bank can pay.
Aligners spend a heart to capture a neutral reachable junction. Scramblers spend
one to neutralize an enemy junction. Gear stations charge the bank for a new role,
but keeping the same role is free. Zero health removes gear and hearts without
teleporting the Cog. Returning to friendly territory permits recovery.

Territory influence uses integer square roots with 1/1024 precision. Contributions
sum by team and ties are neutral. Disconnected junctions neutralize.
Enemy hubs and gear stations cannot be used.

## Explicit adaptation choices

The original configuration composition and general biome scene graph are not
included. The arena is a fixed export of the original FourScore mission with
32 agents and map seed 1. Its five-cell outer border is removed to retain
the 120 by 120 playable area. Original walls, corner compounds, spawns,
junctions, and extractors are preserved in `data/maps/fourscore.txt`.
The match seed controls the portable simulation RNG, not map geometry.
There is no runtime Python dependency or configurable map generator.

Each turn shuffles the 32 seats with Poly World's portable RNG, resolves each
movement or bump interaction, applies solar and
territory effects, clears broken equipment, and accumulates scores. Invalid or
blocked actions are neutral no-ops. Station use costs energy. The selected
intent for Aligners is neutral-junction capture rather than multi-owner tags.
These choices are explicit code, not configurable handlers.

All gameplay changes require a gameplay version change. A content fingerprint
also catches unversioned changes to the simulation, map recipe, or constants.
Policy and presentation changes do not invalidate action replay.

Gameplay version 3 replaces the two-faction game. Older replays are rejected.
