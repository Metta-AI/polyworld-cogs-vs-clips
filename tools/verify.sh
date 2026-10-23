#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out
nim check src/cvc.nim
nim check tests/tests.nim
nim r -d:release tests/tests.nim
nim r -d:release tests/signatures.nim
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
