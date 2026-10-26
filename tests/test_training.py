"""Verify Python buffer shapes, determinism, ownership and ABI errors."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'training'))
from environment import Environment

library = sys.argv[1] if len(sys.argv) > 1 else 'out/libcvc.dylib'
first = Environment(library, matches=2, max_ticks=3)
second = Environment(library, matches=2, max_ticks=3)
try:
    obs, _ = first.reset(12)
    other, _ = second.reset(12)
    assert obs.shape == (64, 2048, 3) and obs.dtype == np.uint8
    assert np.array_equal(obs, other)
    actions = np.arange(64) % 5
    for tick in range(8):
        result = first.step(actions)
        reference = second.step(actions)
        for a, b in zip(result[:4], reference[:4]):
            assert np.array_equal(a, b)
        assert bool(first.terminals.all()) == (tick % 3 == 2)
        assert np.isfinite(first.rewards).all()
    before = first.library.cvc_hash(first.handle, 0)
    for invalid in [np.full(64, 5), np.zeros(63, dtype=int), np.zeros(64)]:
        try:
            first.step(invalid)
            raise AssertionError('Accepted invalid actions')
        except ValueError:
            pass
    assert first.library.cvc_hash(first.handle, 0) == before
finally:
    first.close()
    second.close()
first.close()
print('Python training buffers, determinism, terminals and validation pass.')
