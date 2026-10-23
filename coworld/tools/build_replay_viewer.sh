#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./tools/build_browser.sh
python3 coworld/tools/package_viewer.py "$1"
