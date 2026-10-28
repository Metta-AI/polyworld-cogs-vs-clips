# CoWorld hosting

The package in `coworld/` publishes as **Cogs vs Clips PW**. It uses
`game-hosted` BASIC file players, 32 seats, four teams of eight, and the
fixed 10,000-tick FourScore rules. Seats are grouped red, blue, green,
yellow. Each seat receives its team's territory score.

The adapter imports Polyworld's existing CoWorld handoff and logging module.
It reads staged file URIs, keeps PRINT and BASIC errors in private seat logs,
reports compilation failures with the failed seat index, and writes replay
and player status before the final results marker. The health and legacy
WebSocket probes stay available until the platform collects the episode.
The simulation and ordinary desktop/headless builds retain their existing
behavior. The server image is built for Linux amd64 from pinned dependencies.

The static viewer uses the same WASM simulation and renderer. It reads the
replay URL from the fragment, with the query parameter as a fallback,
detects gzip/zlib replay bytes, and writes them into Emscripten's filesystem.
It signals readiness after the first rendered frame. Download and replay
errors remain visible. Replay state, seeking, speed controls, and graphics
come from the normal Polyworld client.

Use a CoWorld CLI revision supporting `game-hosted` file players, Docker,
Nim 2.2.10, and Emscripten:

```sh
nim check -d:headless -d:coworld src/cvc.nim
nim c -d:release -d:headless -d:coworld -o:out/cvc-coworld src/cvc.nim
nim c -d:release -d:headless -o:out/cvc-headless src/cvc.nim
python3 tests/test_hosted.py
coworld build --project coworld --version VERSION
coworld certify coworld/dist/coworld_manifest.json --no-open-report --timeout-seconds 1800
coworld upload-coworld coworld/dist/coworld_manifest.json --wait-certification
```

Build and upload outputs are ignored by Git. The build hook recreates the
viewer bundle and includes the unchanged `players/base.bas` baseline.
The local adapter test checks full-length idle episodes, private PRINT
output, health, completion artifacts, and seat-specific compilation failure.

## Current release

Version **0.1.3** fixes hosted score units to match the replay viewer.
All 10 hosted certification checks and five smoke episodes passed on
2026-10-27. CoWorld ID:
`cow_a770ed22-3db9-42eb-b448-9af3863cd566`.
[Verified hosted match](https://softmax.com/observatory/v2/episode-requests/ereq_0c858079-14e5-4e24-af60-5112320713b0/watch).

## Release 0.1.2

On 2026-10-23, **Cogs vs Clips PW 0.1.2** became public, canonical, and
certified on Softmax. CoWorld ID:
`cow_c88ad5c1-c84a-4258-bd17-9a6a4083e075`.

The server image and browser viewer both include the exact integer distance
lookup and batched territory calculation from commit `11afcd3`. All 10 hosted
certification checks and all five hosted smoke episodes passed. The receipt
is [coworld-release.json](coworld-release.json).
[Watch a hosted replay](https://softmax.com/observatory/v2/episode-requests/ereq_04d0ddcc-71d8-4ac3-ae22-05b42674d46f/watch).

Local simulation-only benchmarks measured 0.116 seconds per 10,000 ticks,
versus 0.291 seconds for C++ without observations, about 2.5 times faster.
See [simulation-performance.md](simulation-performance.md) for methods,
limitations, and deterministic replay verification. This is not a measurement
of hosted end-to-end bot match runtime.

## Previous release

On 2026-10-23, **Cogs vs Clips PW 0.1.1** became public, canonical, and
certified on Softmax. CoWorld ID:
`cow_93ddca57-3036-4253-9675-a97c2621a275`.

All 10 hosted certification checks and all five hosted smoke episodes passed.
The previous receipt is retained in Git history.
[Watch a verified hosted replay](https://softmax.com/observatory/v2/episode-requests/ereq_0bb817e8-8b42-4ea8-b840-bada6704a77e/watch).

The 0.1.1 viewer uses compiled Emscripten callbacks to comply with the hosting
Content Security Policy. The browser entry point applies the same script
policy locally, so string-evaluation regressions are caught before upload.
The release reuses the 0.1.0 server image and baseline files. That server's
10,000-tick replay verified on native macOS with final hash `3548051309`.
The 0.1.1 hosted replay was also visually checked with the original graphics,
playback controls, and the loading overlay dismissed.

## Score units

The viewer, headless summary, and hosted episode results report territory
scores divided by 10,000. For example, raw 338461 becomes 33.8461, shown as
33.85 in the viewer. Hosted scores retain fractional precision. League
averages can differ from the score in one replay. OpenSkill ratings are a
separate quantity. Simulation state and replay hashes retain raw integers.
Previously completed hosted results keep their original score units.
