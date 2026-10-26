"""Evaluate a saved baseline against its initial policy on fixed self-play seeds."""
import argparse
import json
from pathlib import Path
import time

import numpy as np
import torch

from environment import Environment
from policy import Policy


def evaluate(policy, library, seeds):
    env = Environment(library, matches=len(seeds))
    # Matches use sequential seeds; each side receives exactly the same seeds.
    observation, _ = env.reset(seeds[0])
    torch.manual_seed(12345)
    actions_count = np.zeros(5, dtype=np.int64)
    reward = 0.0
    started = time.monotonic()
    try:
        with torch.no_grad():
            for tick in range(10000):
                logits, _ = policy(torch.from_numpy(observation))
                actions = torch.distributions.Categorical(logits=logits).sample().numpy()
                actions_count += np.bincount(actions, minlength=5)
                observation, rewards, done, _, _ = env.step(actions)
                reward += float(rewards.sum())
            assert done.all()
        return dict(seconds=time.monotonic() - started, reward_sum=reward,
                    action_counts=actions_count.tolist(),
                    stats={key: getattr(env.stats, key) for key, _ in env.stats._fields_})
    finally:
        env.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--library', default='out/libcvc.dylib')
    parser.add_argument('--seed', type=int, default=1001)
    parser.add_argument('--matches', type=int, default=4)
    parser.add_argument('--output', type=Path, default=Path('out/train-baseline/evaluation.json'))
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.manual_seed(42)
    policy = Policy()
    seeds = list(range(args.seed, args.seed + args.matches))
    initial = evaluate(policy, args.library, seeds)
    policy.load_state_dict(torch.load(args.checkpoint, weights_only=True))
    policy.eval()
    trained = evaluate(policy, args.library, seeds)
    result = dict(seeds=seeds, initial_self_play=initial, trained_self_play=trained,
                  note='Separate self-play rollouts, not a head-to-head strength test.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
