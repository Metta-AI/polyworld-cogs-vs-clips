#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p out
nim c -d:release -o:out/cvc src/cvc.nim
nim c -d:release -d:headless -o:out/cvc-headless src/cvc.nim
