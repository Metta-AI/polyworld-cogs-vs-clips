#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out/browser
nim c -d:release -d:emscripten --threads:off \
  --nimcache:out/cache-browser -o:out/browser/cvc.js src/cvc.nim
cp tools/browser.html out/browser/index.html
