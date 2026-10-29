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

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "training"))

from environment import Environment
from policy import Policy
from evaluate import evaluate


class UnavailableUtilization:
    """Keep optional dashboard metrics unavailable when macOS hides CPU data."""
    def __init__(self):
        self.cpu_util = self.cpu_mem = self.gpu_util = self.gpu_mem = [float('nan')]

    def stop(self):
        """No monitoring thread was started."""


def main():
    """Train PPO for the requested duration and retain evaluation evidence."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', default='out/libcvc.dylib' if platform.system() == 'Darwin' else 'out/libcvc.so')
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--matches', type=int, default=4)
    parser.add_argument('--max-ticks', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--output', type=Path, default=Path('out/train-baseline'))
    parser.add_argument('--checkpoint', type=Path)
    parser.add_argument('--learning-rate', type=float, default=3e-4)
    parser.add_argument('--entropy', type=float, default=0.01)
    parser.add_argument('--evaluate', action='store_true',
                        help='Compare initial and trained self-play on four held-out full matches')
    args = parser.parse_args()
    if (not np.isfinite(args.seconds) or args.seconds <= 0 or args.threads < 1
            or not 1 <= args.matches <= 128 or not 1 <= args.max_ticks <= 10000
            or not np.isfinite(args.learning_rate) or args.learning_rate <= 0
            or not np.isfinite(args.entropy) or args.entropy < 0):
        parser.error('Invalid duration, threads, matches, ticks, learning rate, or entropy')
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Use a new or empty output directory to preserve prior runs')
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
                  learning_rate=args.learning_rate, anneal_lr=False, batch_size=env.num_agents * 32,
                  bptt_horizon=32, minibatch_size=512, max_minibatch_size=512,
                  update_epochs=2, total_timesteps=1_000_000_000,
                  ent_coef=args.entropy, vf_coef=0.5, checkpoint_interval=10000,
                  seed=args.seed, data_dir=str(args.output), compile=False)
    # PufferLib 3 divides by psutil.cpu_count(), which can be None in a sandbox.
    monitor = pufferlib.pufferl.Utilization
    monitoring = pufferlib.pufferl.psutil.cpu_count() is not None
    try:
        if not monitoring:
            pufferlib.pufferl.Utilization = UnavailableUtilization
        trainer = pufferlib.pufferl.PuffeRL(config, env, policy)
    finally:
        pufferlib.pufferl.Utilization = monitor
    trainer.print_dashboard = lambda *a, **kw: None
    started = time.monotonic()
    torch.save(initial, args.output / 'initial.pt')
    trainer_source = Path(__file__).read_bytes()
    (args.output / 'train_puffer.py').write_bytes(trainer_source)
    library_hash = hashlib.sha256(Path(args.library).read_bytes()).hexdigest()
    logs = args.output / 'metrics.jsonl'
    last_report = started
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
                if time.monotonic() - last_report >= 30:
                    last_report = time.monotonic()
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
                       arguments={key: str(value) if isinstance(value, Path) else value
                                  for key, value in vars(args).items()},
                       trainer_sha256=hashlib.sha256(trainer_source).hexdigest(),
                       utilization_available=monitoring,
                       source_dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], text=True)),
                       library_sha256=library_hash,
                       source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip())
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        trainer.close()
    if args.evaluate:
        seeds = list(range(1001, 1005))
        trained = evaluate(policy.eval(), args.library, seeds)
        policy.load_state_dict(initial)
        before = evaluate(policy.eval(), args.library, seeds)
        result = dict(seeds=seeds, initial_self_play=before,
                      trained_self_play=trained,
                      note='Separate self-play rollouts, not head-to-head strength or ladder wins.')
        (args.output / 'evaluation.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    main()
