"""Recreate the CoWorld viewer bundle from the current browser build."""
from pathlib import Path
import shutil
import sys
root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve()
if output != root / 'coworld/dist/replay-viewer' and output != root / 'coworld/replay-viewer':
    raise SystemExit('Unexpected viewer output: ' + str(output))
if output.exists():
    shutil.rmtree(output)
shutil.copytree(root / 'out/browser', output)
