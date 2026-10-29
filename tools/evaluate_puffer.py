"""Compare a PufferLib MLP checkpoint with its initializer against base.bas."""
import argparse
import ctypes
import json
from pathlib import Path
import sys
import time

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'training'))
from environment import Environment
from policy import Policy


def evaluate(policy, library, seed):
    """Play four full games, assigning the learned team to each corner once."""
    env = Environment(library, matches=4)
    lib = env.library
    integers = np.ctypeslib.ndpointer(dtype=np.int32, flags='C_CONTIGUOUS')
    scores_type = np.ctypeslib.ndpointer(dtype=np.int64, flags='C_CONTIGUOUS')
    lib.cvc_baseline.argtypes = [ctypes.c_void_p, integers]
    lib.cvc_baseline.restype = ctypes.c_int
    lib.cvc_scores.argtypes = [ctypes.c_void_p, scores_type]
    lib.cvc_scores.restype = ctypes.c_int
    actions = np.empty(128, dtype=np.int32)
    scores = np.empty(16, dtype=np.int64)
    seats = np.concatenate([np.arange(i * 32 + i * 8,
                                     i * 32 + (i + 1) * 8) for i in range(4)])
    started = time.monotonic()
    torch.manual_seed(12345)
    try:
        observations, _ = env.reset(seed)
        policy.eval()
        with torch.no_grad():
            for tick in range(10000):
                env._check(lib.cvc_baseline(env.handle, actions))
                logits, _ = policy(torch.from_numpy(observations[seats]))
                actions[seats] = torch.distributions.Categorical(logits=logits).sample().numpy()
                observations, _, done, _, _ = env.step(actions)
            assert done.all()
        env._check(lib.cvc_scores(env.handle, scores))
        rows = []
        for i, values in enumerate(scores.reshape(4, 4)):
            own = int(values[i])
            opponents = [int(value) for j, value in enumerate(values) if j != i]
            rows.append(dict(seed=seed + i, team=i,
                             scores=(values / 10000).tolist(),
                             score=own / 10000,
                             opponent_mean=float(np.mean(opponents)) / 10000,
                             rank=1 + sum(value > own for value in opponents),
                             outright_win=own > max(opponents)))
        return dict(seconds=time.monotonic() - started, games=rows,
                    mean_score=float(np.mean([row['score'] for row in rows])),
                    outright_wins=sum(row['outright_win'] for row in rows))
    finally:
        env.close()


def main():
    """Load safe state dictionaries and save paired match results."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--initial', type=Path, required=True)
    parser.add_argument('--library', default='out/libcvc.dylib'
                        if sys.platform == 'darwin' else 'out/libcvc.so')
    parser.add_argument('--seed', type=int, default=2001)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    policy = Policy()
    result = dict(note='Eight learned cogs versus 24 base.bas cogs per game. '
                       'Four paired seeds, one team rotation each. Small diagnostic, not a win-rate estimate.')
    for label, path in [('initial', args.initial), ('trained', args.checkpoint)]:
        policy.load_state_dict(torch.load(path, weights_only=True))
        result[label] = evaluate(policy, args.library, args.seed)
        print(label, json.dumps(result[label]), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
