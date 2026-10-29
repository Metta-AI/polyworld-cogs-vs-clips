"""Run Safa's active FourScore role curriculum with his masked PuffeRL."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'training'))
import safa_pufferl
from safa import SafaEnvironment, SafaPolicy, PPO, SOURCE
from train_puffer import UnavailableUtilization


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--steps', type=int, default=5_000_000_000)
    parser.add_argument('--matches', type=int, default=1)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--device', choices=['cpu', 'cuda'], default='cpu')
    parser.add_argument('--max-ticks', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=42)
    parser.add_argument('--checkpoint', type=Path)
    parser.add_argument('--library', default='out/libcvc.dylib' if sys.platform == 'darwin' else 'out/libcvc.so')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not np.isfinite(args.seconds) or args.seconds <= 0 or args.threads < 1 or args.steps < 1:
        parser.error('Duration, steps and threads must be positive')
    if args.device == 'cuda' and not torch.cuda.is_available():
        parser.error('CUDA requested but no CUDA device is available')
    if args.output.exists() and any(args.output.iterdir()):
        parser.error('Output must be new or empty')
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    env = SafaEnvironment(args.library, args.matches, args.max_ticks)
    policy = SafaPolicy().to(args.device)
    if args.checkpoint:
        policy.load_state_dict(torch.load(args.checkpoint, map_location='cpu', weights_only=True))
    initial = {k: v.detach().cpu().clone() for k, v in policy.state_dict().items()}
    torch.save(initial, args.output / 'initial.pt')
    argv = sys.argv
    try:
        sys.argv = [sys.argv[0]]
        # Config is supplied by installed PufferLib; Safa overrides are explicit.
        import pufferlib.pufferl
        config = pufferlib.pufferl.load_config('default')['train']
    finally:
        sys.argv = argv
    config.update(PPO)
    config.update(env='cvc_safa', device=args.device, optimizer='adam', use_rnn=True,
                  batch_size=env.num_agents * 32, bptt_horizon=32,
                  minibatch_size=256, max_minibatch_size=256,
                  total_timesteps=args.steps, checkpoint_interval=10000,
                  seed=args.seed, data_dir=str(args.output), compile=False,
                  torch_deterministic=True, cpu_offload=False, precision='float32')
    if safa_pufferl.psutil.cpu_count() is None:
        safa_pufferl.Utilization = UnavailableUtilization
    trainer = safa_pufferl.PuffeRL(config, env, policy)
    trainer.print_dashboard = lambda *a, **kw: None
    sources = [Path(__file__), ROOT / 'training/safa.py', ROOT / 'training/safa_pufferl.py',
               ROOT / 'src/cvc/training.nim', ROOT / 'src/cvc/neuralviews.nim']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    for path in sources:
        snapshot = args.output / 'sources' / path.relative_to(ROOT)
        snapshot.parent.mkdir(parents=True, exist_ok=True)
        snapshot.write_bytes(path.read_bytes())
    started = last_report = time.monotonic()
    try:
        with (args.output / 'metrics.jsonl').open('w') as log:
            while time.monotonic() - started < args.seconds and trainer.global_step < args.steps:
                trainer.evaluate()
                metrics = trainer.train()
                if not all(torch.isfinite(p).all() for p in policy.parameters()):
                    raise FloatingPointError('Non-finite policy')
                if metrics:
                    log.write(json.dumps(metrics) + '\n')
                    log.flush()
                if time.monotonic() - last_report >= 30:
                    last_report = time.monotonic()
                    print(f'{last_report-started:.1f}s: {trainer.global_step} steps, '
                          f'{trainer.epoch} updates, {env.native.stats.episodes} matches', flush=True)
            elapsed = time.monotonic() - started
            checkpoint = trainer.save_checkpoint()
            summary = dict(seconds=elapsed, agent_steps=trainer.global_step,
                           updates=trainer.epoch, checkpoint=str(checkpoint),
                           steps_per_second=trainer.global_step / elapsed,
                           weight_change_l2=sum(float((v.cpu() - initial[k]).square().sum())
                                                for k, v in policy.state_dict().items()) ** .5,
                           reward_sum=env.total_reward, active_event_totals=env.event_totals.tolist(),
                           native_stats={k: getattr(env.native.stats, k) for k, _ in env.native.stats._fields_},
                           config=config, source=SOURCE, source_hashes=hashes,
                           library_sha256=hashlib.sha256(Path(args.library).read_bytes()).hexdigest(),
                           initial_checkpoint=str(args.checkpoint), torch=torch.__version__)
            (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(json.dumps(summary, indent=2), flush=True)
    finally:
        trainer.close()


if __name__ == '__main__':
    main()
