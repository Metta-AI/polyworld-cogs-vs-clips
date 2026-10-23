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
python3 tests/test_hosted.py
coworld build --project coworld --version 0.1.0
coworld certify coworld/dist/coworld_manifest.json --no-open-report --timeout-seconds 1800
coworld upload-coworld coworld/dist/coworld_manifest.json --wait-certification
```

Build and upload outputs are ignored by Git. The build hook recreates the
viewer bundle and includes the unchanged `players/base.bas` baseline.
The local adapter test checks full-length idle episodes, private PRINT
output, health, completion artifacts, and seat-specific compilation failure.
