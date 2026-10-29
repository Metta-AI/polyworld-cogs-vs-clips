"""Evaluate a trained Safa network on full games against base.bas."""
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
from safa import SafaEnvironment, SafaPolicy, ACTION_MAP


def evaluate(checkpoint, library, seed=2001, matches=4):
    """Place eight learned generalists in a different corner of each full game."""
    policy = SafaPolicy().eval()
    policy.load_state_dict(torch.load(checkpoint, map_location='cpu', weights_only=True))
    env = SafaEnvironment(library, matches)
    lib = env.native.library
    integers = np.ctypeslib.ndpointer(dtype=np.int32, flags='C_CONTIGUOUS')
    long_integers = np.ctypeslib.ndpointer(dtype=np.int64, flags='C_CONTIGUOUS')
    lib.cvc_baseline.argtypes = [ctypes.c_void_p, integers]
    lib.cvc_baseline.restype = ctypes.c_int
    lib.cvc_scores.argtypes = [ctypes.c_void_p, long_integers]
    lib.cvc_scores.restype = ctypes.c_int
    actions = np.empty(matches * 32, np.int32)
    scores = np.empty(matches * 4, np.int64)
    seats = np.concatenate([np.arange(i * 32 + (i % 4) * 8,
                                     i * 32 + (i % 4 + 1) * 8) for i in range(matches)])
    inverse = np.argsort(ACTION_MAP)
    memory = dict(lstm_h=torch.zeros(len(seats),512), lstm_c=torch.zeros(len(seats),512))
    torch.manual_seed(12345)
    started = time.monotonic()
    try:
        env.reset(seed)
        # Deployment uses all-generalist roles, no idle action substitution.
        env.roles.fill(3)
        env.observe()
        with torch.no_grad():
            for tick in range(10000):
                env.native._check(lib.cvc_baseline(env.native.handle, actions))
                legacy = inverse[actions].astype(np.int32)
                logits, _ = policy(torch.from_numpy(env.observations[seats]), memory)
                legacy[seats] = torch.distributions.Categorical(logits=logits).sample().numpy()
                _, _, done, _, _ = env.step(legacy)
                if (tick + 1) % 1000 == 0:
                    print(f'Evaluation {tick + 1}/10000 ticks, {time.monotonic()-started:.1f}s',flush=True)
            assert done.all()
        env.native._check(lib.cvc_scores(env.native.handle, scores))
        rows = []
        for i, values in enumerate(scores.reshape(matches,4)):
            own = int(values[i % 4])
            opponents = [int(v) for j,v in enumerate(values) if j != i % 4]
            rows.append(dict(seed=seed+i,team=i%4,scores=(values/10000).tolist(),
                             score=own/10000,opponent_mean=float(np.mean(opponents))/10000,
                             rank=1+sum(v>own for v in opponents),outright_win=own>max(opponents)))
        return dict(seconds=time.monotonic()-started,checkpoint=str(checkpoint),games=rows,
                    mean_score=float(np.mean([r['score'] for r in rows])),
                    outright_wins=sum(r['outright_win'] for r in rows),
                    note='Eight neural generalists versus 24 base.bas cogs. Small held-out diagnostic.')
    finally:
        env.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint',type=Path)
    parser.add_argument('--library',default='out/libcvc.dylib' if sys.platform=='darwin' else 'out/libcvc.so')
    parser.add_argument('--threads',type=int,default=1)
    parser.add_argument('--matches',type=int,default=4)
    parser.add_argument('--seed',type=int,default=2001)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    if args.matches < 1 or args.threads < 1:
        parser.error('Matches and threads must be positive')
    torch.set_num_threads(args.threads)
    result = evaluate(args.checkpoint,args.library,args.seed,args.matches)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)


if __name__ == '__main__':
    main()
