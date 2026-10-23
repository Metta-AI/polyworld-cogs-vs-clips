#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out/browser
nim c -d:release -d:emscripten --threads:off \
  --nimcache:out/cache-browser -o:out/browser/cvc.js src/cvc.nim
python3 - <<'PYBUILD'
from pathlib import Path
from hashlib import sha256
output = Path('out/browser')
version = sha256((output / 'cvc.wasm').read_bytes()).hexdigest()[:16]
html = Path('tools/browser.html').read_text().replace('__BUILD_ID__', version)
(output / 'index.html').write_text(html)
PYBUILD
