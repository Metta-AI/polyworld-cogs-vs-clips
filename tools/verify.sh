#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out
nim check tests/test_motions.nim
nim check tests/test_bars.nim
nim check tests/test_plans.nim
nim check tests/test_territories.nim
nim check -d:cvcSimTrace experiments/bench_steps.nim
nim check src/cvc.nim
nim check -d:CvcTracePath=out/check-profile.json src/cvc.nim
nim check -d:testPipes tests/test_pipes.nim
nim check tests/test_timings.nim
nim check tests/test_tracks.nim
nim check tests/test_yields.nim
nim check -d:testPipes tests/test_scrubs.nim
nim check tests/test_routes.nim
nim check tests/test_observations.nim
nim check tests/test_directors.nim
nim check -d:headless tests/test_training.nim
nim check tests/tests.nim
nim check tests/test_options.nim
nim r -d:release tests/test_observations.nim
nim r -d:release tests/test_directors.nim
nim r -d:release -d:headless tests/test_training.nim
nim r -d:release tests/test_motions.nim
nim r -d:release tests/test_bars.nim
nim r -d:release tests/test_plans.nim
nim r -d:release tests/test_territories.nim
nim r -d:release --nimcache:out/cache-options tests/test_options.nim
nim r -d:release --nimcache:out/cache-timings tests/test_timings.nim
nim r -d:release tests/test_tracks.nim
nim r -d:release tests/test_yields.nim
nim r -d:release -d:testPipes --nimcache:out/cache-scrubs tests/test_scrubs.nim
nim r -d:release --nimcache:out/cache-tests tests/tests.nim
nim r -d:release --nimcache:out/cache-routes tests/test_routes.nim
nim r -d:release -d:testPipes --nimcache:out/cache-pipes tests/test_pipes.nim
nim r -d:release --nimcache:out/cache-signatures tests/signatures.nim
nim c -d:release -d:headless -d:emscripten --threads:off \
  --nimcache:out/cache-conformance \
  --passL:"--preload-file out/seed-1.replay@native.replay" \
  -o:out/signatures.cjs tests/signatures.nim
(cd out && node signatures.cjs > wasm-signatures.csv)
python3 - <<'PY'
from pathlib import Path
expected = ''.join(Path(f'out/signatures-{seed}.csv').read_text() for seed in [1, 42, -1])
actual = Path('out/wasm-signatures.csv').read_text()
assert actual == expected, 'Native and WebAssembly tick hashes differ'
print('30,000 native/WebAssembly tick hashes match.')
PY
