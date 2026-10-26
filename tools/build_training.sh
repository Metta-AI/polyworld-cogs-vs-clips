#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "$(uname -s)" in
  Darwin) library=out/libcvc.dylib ;;
  *) library=out/libcvc.so ;;
esac
nim check -d:headless src/cvc/training.nim
nim c -d:release -d:headless --app:lib -o:"$library" src/cvc/training.nim
