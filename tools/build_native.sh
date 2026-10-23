#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out
nim c -d:release --nimcache:out/cache-native -o:out/cvc src/cvc.nim
nim c -d:release -d:headless --nimcache:out/cache-headless -o:out/cvc-headless src/cvc.nim
