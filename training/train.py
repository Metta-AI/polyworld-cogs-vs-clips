"""Run an actual PufferLib PPO baseline for a bounded wall-clock duration."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import time

import numpy as np
import torch
import pufferlib.pufferl

from environment import Environment
from policy import Policy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', default='out/libcvc.dylib' if platform.system() == 'Darwin' else 'out/libcvc.so')
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--matches', type=int, default=4)
    parser.add_argument('--max-ticks', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--output', type=Path, default=Path('out/train-baseline'))
    parser.add_argument('--checkpoint', type=Path)
    args = parser.parse_args()
    if args.seconds <= 0 or args.threads < 1:
        parser.error('seconds and threads must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    env = Environment(args.library, args.matches, args.max_ticks)
    policy = Policy(env.single_observation_space.shape[0])
    if args.checkpoint:
        policy.load_state_dict(torch.load(args.checkpoint, weights_only=True))
    initial = {key: value.detach().clone() for key, value in policy.state_dict().items()}
    arguments = sys.argv
    try:
        sys.argv = [sys.argv[0]]
        config = pufferlib.pufferl.load_config('default')['train']
    finally:
        sys.argv = arguments
    config.update(env='cvc', device='cpu', optimizer='adam', use_rnn=False,
                  learning_rate=3e-4, anneal_lr=False, batch_size=env.num_agents * 32,
                  bptt_horizon=32, minibatch_size=512, max_minibatch_size=512,
                  update_epochs=2, total_timesteps=1_000_000_000,
                  ent_coef=0.01, vf_coef=0.5, checkpoint_interval=10000,
                  seed=args.seed, data_dir=str(args.output), compile=False)
    trainer = pufferlib.pufferl.PuffeRL(config, env, policy)
    trainer.print_dashboard = lambda *a, **kw: None
    started = time.monotonic()
    logs = args.output / 'metrics.jsonl'
    try:
        with logs.open('w') as output:
            while time.monotonic() - started < args.seconds:
                trainer.evaluate()
                metrics = trainer.train()
                if not all(torch.isfinite(p).all() for p in policy.parameters()):
                    raise FloatingPointError('Non-finite policy weights')
                if metrics:
                    output.write(json.dumps(metrics) + '\n')
                    output.flush()
                if trainer.epoch % 10 == 0:
                    print(f'{time.monotonic()-started:.1f}s: {trainer.global_step} agent steps, '
                          f'{trainer.epoch} updates, {env.stats.episodes} matches', flush=True)
        elapsed = time.monotonic() - started
        path = trainer.save_checkpoint()
        delta = sum(float((value - initial[key]).square().sum())
                    for key, value in policy.state_dict().items()) ** 0.5
        summary = dict(seconds=elapsed, agent_steps=trainer.global_step,
                       updates=trainer.epoch, steps_per_second=trainer.global_step / elapsed,
                       weight_change_l2=delta, checkpoint=str(path),
                       reward_sum=env.total_reward,
                       native_stats={name: getattr(env.stats, name) for name, _ in env.stats._fields_},
                       config=config, torch=torch.__version__,
                       library_sha256=hashlib.sha256(Path(args.library).read_bytes()).hexdigest(),
                       source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip())
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        trainer.close()


if __name__ == '__main__':
    main()
