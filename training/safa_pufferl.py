# Vendored Safa PuffeRL, MIT license in safa_pufferl.LICENSE.
# Source: Metta-AI/cvc-fourscore-rl-experiments at ba2cbbace118369d405d3087febec62adc73dee9.
# Path: cogame-cogsguard/src/cogsguard/vendor/pufferl.py.
# Local compatibility change: seven-field native recv tuple.
# TODO: Add information
# - Help menu
# - Docs link
# python -m torch.distributed.run --standalone --nnodes=1 --nproc-per-node=1 clean_pufferl.py --env puffer_nmmo3 --mode train  # noqa: E501
# torchrun --standalone --nnodes=1 --nproc-per-node=6 -m pufferlib.pufferl train puffer_nmmo3
import warnings

warnings.filterwarnings("error", category=RuntimeWarning)


def record(fn):
    """Lazy import wrapper for torch.distributed.elastic.multiprocessing.errors.record.

    This is defined before other imports to avoid triggering torch.distributed import on macOS,
    which causes a warning about unsupported redirects.
    """
    try:
        from torch.distributed.elastic.multiprocessing.errors import record as _record

        return _record(fn)
    except ImportError:
        return fn


# ruff: noqa: E402
# Imports below are intentionally after the record function definition to avoid torch.distributed warnings
import argparse
import ast
import configparser
import glob
import importlib
import os
import random
import shutil
import sys
import time
from collections import defaultdict, deque
import threading
from threading import Thread

import numpy as np
import psutil
import torch
import torch.distributed
import torch.utils.cpp_extension

import pufferlib
import pufferlib.pytorch
import pufferlib.sweep
import pufferlib.vector

try:
    from pufferlib import _C  # noqa: F401 — registers torch.ops.pufferlib.* kernels

    _C_AVAILABLE = True
except ImportError:
    import logging as _logging

    _logging.getLogger("pufferlib").warning(
        "Could not load pufferlib._C extension (likely missing CUDA runtime). "
        "Training will use a pure-PyTorch fallback for advantage computation."
    )
    _C_AVAILABLE = False

import rich
import rich.traceback
from rich.console import Console
from rich.table import Table
from rich_argparse import RichHelpFormatter

rich.traceback.install(show_locals=False)

import signal  # Aggressively exit on ctrl+c

if threading.current_thread() is threading.main_thread():
    try:
        signal.signal(signal.SIGINT, lambda sig, frame: os._exit(0))
    except ValueError:
        pass  # Not in main thread of the main interpreter (e.g. subprocess worker)

def _has_advantage_cuda_kernel() -> bool:
    try:
        return bool(torch._C._dispatch_has_kernel_for_dispatch_key("pufferlib::compute_puff_advantage", "CUDA"))
    except RuntimeError:
        return False


# Detect the kernel on the loaded extension, not from build tools present on the host.
ADVANTAGE_CUDA = _has_advantage_cuda_kernel()


class PuffeRL:
    def __init__(self, config, vecenv, policy, logger=None):
        # Backend perf optimization
        torch.backends.cudnn.deterministic = config["torch_deterministic"]
        torch.backends.cudnn.benchmark = True

        # Reproducibility
        seed = config["seed"]
        # random.seed(seed)
        # np.random.seed(seed)
        # torch.manual_seed(seed)

        # Vecenv info
        vecenv.async_reset(seed)
        obs_space = vecenv.single_observation_space
        atn_space = vecenv.single_action_space
        total_agents = vecenv.num_agents
        self.total_agents = total_agents

        # Experience
        if config["batch_size"] == "auto" and config["bptt_horizon"] == "auto":
            raise pufferlib.APIUsageError("Must specify batch_size or bptt_horizon")
        elif config["batch_size"] == "auto":
            config["batch_size"] = total_agents * config["bptt_horizon"]
        elif config["bptt_horizon"] == "auto":
            config["bptt_horizon"] = config["batch_size"] // total_agents

        batch_size = config["batch_size"]
        horizon = config["bptt_horizon"]
        segments = batch_size // horizon
        self.segments = segments
        if total_agents > segments:
            raise pufferlib.APIUsageError(f"Total agents {total_agents} <= segments {segments}")

        device = config["device"]
        self.observations = torch.zeros(
            segments,
            horizon,
            *obs_space.shape,
            dtype=pufferlib.pytorch.numpy_to_torch_dtype_dict[obs_space.dtype],
            pin_memory=device == "cuda" and config["cpu_offload"],
            device="cpu" if config["cpu_offload"] else device,
        )
        self.actions = torch.zeros(
            segments,
            horizon,
            *atn_space.shape,
            device=device,
            dtype=pufferlib.pytorch.numpy_to_torch_dtype_dict[atn_space.dtype],
        )
        self.values = torch.zeros(segments, horizon, device=device)
        self.logprobs = torch.zeros(segments, horizon, device=device)
        self.rewards = torch.zeros(segments, horizon, device=device)
        # >>> COGAMES MASK
        # Per-timestep loss mask, parallel to self.rewards. 1.0 = include the
        # transition in the PPO loss, 0.0 = exclude it (no policy/value/entropy
        # gradient). Defaults to all-ones so behavior is identical to upstream
        # unless the env supplies a mask via info["_cogames_train_mask"].
        self.train_mask = torch.ones(segments, horizon, device=device)
        # <<< COGAMES MASK
        self.terminals = torch.zeros(segments, horizon, device=device)
        self.truncations = torch.zeros(segments, horizon, device=device)
        self.ratio = torch.ones(segments, horizon, device=device)
        self.importance = torch.ones(segments, horizon, device=device)
        self.ep_lengths = torch.zeros(total_agents, device=device, dtype=torch.int32)
        self.ep_indices = torch.arange(total_agents, device=device, dtype=torch.int32)
        self.free_idx = total_agents

        # >>> COGAMES PER-AGENT GAMMA
        # Exact experience-row -> per-env agent index mapping, maintained at
        # every row assignment (init, mid-rollout reassignment, end-of-rollout
        # reset). Used only when config["per_agent_gamma"] is set; requires
        # config["per_agent_gamma_num_agents"] (agents per env).
        nape = int(config.get("per_agent_gamma_num_agents") or 0)
        self._agent_of_global = (
            torch.arange(total_agents, device=device, dtype=torch.int64) % nape
            if nape > 0
            else torch.zeros(total_agents, device=device, dtype=torch.int64)
        )
        self.row_agent = torch.zeros(segments, device=device, dtype=torch.int64)
        n0 = min(total_agents, segments)
        self.row_agent[:n0] = self._agent_of_global[:n0]
        # <<< COGAMES PER-AGENT GAMMA

        # LSTM
        if config["use_rnn"]:
            n = vecenv.agents_per_batch
            h = policy.hidden_size
            self.lstm_h = {i * n: torch.zeros(n, h, device=device) for i in range(total_agents // n)}
            self.lstm_c = {i * n: torch.zeros(n, h, device=device) for i in range(total_agents // n)}

        # Minibatching & gradient accumulation
        minibatch_size = config["minibatch_size"]
        max_minibatch_size = config["max_minibatch_size"]
        self.minibatch_size = min(minibatch_size, max_minibatch_size)
        if minibatch_size > max_minibatch_size and minibatch_size % max_minibatch_size != 0:
            raise pufferlib.APIUsageError(
                f"minibatch_size {minibatch_size} > max_minibatch_size {max_minibatch_size} must divide evenly"
            )

        if batch_size < minibatch_size:
            raise pufferlib.APIUsageError(f"batch_size {batch_size} must be >= minibatch_size {minibatch_size}")

        self.accumulate_minibatches = max(1, minibatch_size // max_minibatch_size)
        self.total_minibatches = int(config["update_epochs"] * batch_size / self.minibatch_size)
        self.minibatch_segments = self.minibatch_size // horizon
        if self.minibatch_segments * horizon != self.minibatch_size:
            raise pufferlib.APIUsageError(
                f"minibatch_size {self.minibatch_size} must be divisible by bptt_horizon {horizon}"
            )

        # Torch compile
        self.uncompiled_policy = policy
        self.policy = policy
        if config["compile"]:
            self.policy = torch.compile(policy, mode=config["compile_mode"], fullgraph=config["compile_fullgraph"])

        # Optimizer
        if config["optimizer"] == "adam":
            optimizer = torch.optim.Adam(
                self.policy.parameters(),
                lr=config["learning_rate"],
                betas=(config["adam_beta1"], config["adam_beta2"]),
                eps=config["adam_eps"],
            )
        elif config["optimizer"] == "muon":
            from heavyball import ForeachMuon

            warnings.filterwarnings(action="ignore", category=UserWarning, module=r"heavyball.*")
            import heavyball.utils

            heavyball.utils.compile_mode = config["compile_mode"] if config["compile"] else None
            optimizer = ForeachMuon(
                self.policy.parameters(),
                lr=config["learning_rate"],
                betas=(config["adam_beta1"], config["adam_beta2"]),
                eps=config["adam_eps"],
            )
        else:
            raise ValueError(f"Unknown optimizer: {config['optimizer']}")

        self.optimizer = optimizer

        # Logging
        self.logger = logger
        if logger is None:
            self.logger = NoLogger(config)

        # Learning rate scheduler
        epochs = config["total_timesteps"] // config["batch_size"]
        self.scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)
        self.total_epochs = epochs

        # Automatic mixed precision
        precision = config["precision"]
        device = config["device"]
        device_type = device if isinstance(device, str) else device.type
        self.amp_context = torch.amp.autocast(device_type=device_type, dtype=getattr(torch, precision))
        if precision not in ("float32", "bfloat16"):
            raise pufferlib.APIUsageError(f"Invalid precision: {precision}: use float32 or bfloat16")

        # Initializations
        self.config = config
        self.vecenv = vecenv
        self.epoch = 0
        self.global_step = 0
        self.last_log_step = 0
        self.last_log_time = time.time()
        self.start_time = time.time()
        self.utilization = Utilization()
        self.profile = Profile()
        self.stats = defaultdict(list)
        self.last_stats = defaultdict(list)
        self.losses = {}

        # Dashboard
        self.model_size = sum(p.numel() for p in policy.parameters() if p.requires_grad)
        self.print_dashboard(clear=True)

    @property
    def uptime(self):
        return time.time() - self.start_time

    @property
    def sps(self):
        if self.global_step == self.last_log_step:
            return 0

        return (self.global_step - self.last_log_step) / (time.time() - self.last_log_time)

    def evaluate(self):
        profile = self.profile
        epoch = self.epoch
        profile("eval", epoch)
        profile("eval_misc", epoch, nest=True)

        config = self.config
        device = config["device"]

        if config["use_rnn"]:
            for k in self.lstm_h:
                self.lstm_h[k].zero_()
                self.lstm_c[k].zero_()

        self.full_rows = 0
        while self.full_rows < self.segments:
            profile("env", epoch)
            # Polyworld uses the PufferLib 3 seven-field native buffer API.
            o, r, d, t, info, env_id, mask = self.vecenv.recv()

            profile("eval_misc", epoch)
            # TODO: Port to vecenv
            env_id = slice(env_id[0], env_id[-1] + 1)

            # TODO: Handle truncations
            done_mask = d + t
            self.global_step += int(mask.sum())

            profile("eval_copy", epoch)
            o = torch.as_tensor(o)
            o_device = o.to(device)  # , non_blocking=True)
            r = torch.as_tensor(r).to(device)  # , non_blocking=True)
            d = torch.as_tensor(d).to(device)  # , non_blocking=True)

            profile("eval_forward", epoch)
            with torch.no_grad(), self.amp_context:
                state = dict(
                    reward=r,
                    done=d,
                    env_id=env_id,
                    mask=mask,
                )

                if config["use_rnn"]:
                    state["lstm_h"] = self.lstm_h[env_id.start]
                    state["lstm_c"] = self.lstm_c[env_id.start]

                logits, value = self.policy.forward_eval(o_device, state)
                action, logprob, _ = pufferlib.pytorch.sample_logits(logits)
                # Reward clamping DISABLED (stock pufferl clamps to [-1, 1]
                # here): the shared_obs_territory event rewards are hand-sized
                # and multi-event ticks (e.g. several junctions lost at once)
                # must keep their true magnitude.
                # r = torch.clamp(r, -1, 1)

            profile("eval_copy", epoch)
            with torch.no_grad():
                if config["use_rnn"]:
                    self.lstm_h[env_id.start] = state["lstm_h"]
                    self.lstm_c[env_id.start] = state["lstm_c"]

                # Fast path for fully vectorized envs
                l = self.ep_lengths[env_id.start].item()
                batch_rows = slice(self.ep_indices[env_id.start].item(), 1 + self.ep_indices[env_id.stop - 1].item())

                if config["cpu_offload"]:
                    self.observations[batch_rows, l] = o
                else:
                    self.observations[batch_rows, l] = o_device

                self.actions[batch_rows, l] = action
                self.logprobs[batch_rows, l] = logprob
                self.rewards[batch_rows, l] = r
                self.terminals[batch_rows, l] = d.float()
                self.values[batch_rows, l] = value.flatten()

                # >>> COGAMES MASK
                # Pull a per-agent loss mask out of the env infos and store it
                # parallel to rewards. `info` is one dict per env in this chunk;
                # each may carry "_cogames_train_mask" as a per-agent sequence
                # (1.0 keep / 0.0 drop). Concatenated in env order, the result
                # aligns with `r` / `batch_rows` exactly like rewards do. Any
                # env that omits the key contributes all-ones (default keep),
                # so this is a no-op for envs/missions that don't emit it.
                n_chunk = batch_rows.stop - batch_rows.start
                mask_vec = torch.ones(n_chunk, device=device)
                offset = 0
                for env_info in info:
                    env_mask = env_info.get("_cogames_train_mask") if isinstance(env_info, dict) else None
                    if env_mask is None:
                        continue
                    m = torch.as_tensor(np.asarray(env_mask, dtype=np.float32), device=device).flatten()
                    n = m.shape[0]
                    if offset + n <= n_chunk:
                        mask_vec[offset : offset + n] = m
                    offset += n
                self.train_mask[batch_rows, l] = mask_vec
                # <<< COGAMES MASK

                # TODO: Handle masks!!
                # indices = np.where(mask)[0]
                # data.ep_lengths[env_id[mask]] += 1
                self.ep_lengths[env_id] += 1
                if l + 1 >= config["bptt_horizon"]:
                    num_full = env_id.stop - env_id.start
                    self.ep_indices[env_id] = self.free_idx + torch.arange(num_full, device=config["device"]).int()
                    # >>> COGAMES PER-AGENT GAMMA: record the new rows' agents
                    end = min(self.free_idx + num_full, self.row_agent.shape[0])
                    if end > self.free_idx:
                        self.row_agent[self.free_idx:end] = self._agent_of_global[
                            env_id.start : env_id.start + (end - self.free_idx)
                        ]
                    # <<< COGAMES PER-AGENT GAMMA
                    self.ep_lengths[env_id] = 0
                    self.free_idx += num_full
                    self.full_rows += num_full

                action = action.cpu().numpy()
                if isinstance(logits, torch.distributions.Normal):
                    action = np.clip(action, self.vecenv.action_space.low, self.vecenv.action_space.high)

            profile("eval_misc", epoch)
            for i in info:
                for k, v in pufferlib.unroll_nested_dict(i):
                    if isinstance(v, np.ndarray):
                        v = v.tolist()
                    elif isinstance(v, (list, tuple)):
                        self.stats[k].extend(v)
                    else:
                        self.stats[k].append(v)

            profile("env", epoch)
            self.vecenv.send(action)

        profile("eval_misc", epoch)
        self.free_idx = self.total_agents
        self.ep_indices = torch.arange(self.total_agents, device=device, dtype=torch.int32)
        # >>> COGAMES PER-AGENT GAMMA: reset the row->agent map with the rows
        n0 = min(self.total_agents, self.row_agent.shape[0])
        self.row_agent[:n0] = self._agent_of_global[:n0]
        # <<< COGAMES PER-AGENT GAMMA
        self.ep_lengths.zero_()
        profile.end()
        return self.stats

    @record
    def _grouped_puff_advantage(
        self, values, rewards, terminals, ratio, advantages, row_agents, config
    ):
        return _grouped_puff_advantage_impl(
            values, rewards, terminals, ratio, advantages, row_agents, config
        )

    def train(self):
        profile = self.profile
        epoch = self.epoch
        profile("train", epoch)
        losses = defaultdict(float)
        config = self.config
        device = config["device"]

        b0 = config["prio_beta0"]
        a = config["prio_alpha"]
        clip_coef = config["clip_coef"]
        vf_clip = config["vf_clip_coef"]
        anneal_beta = b0 + (1 - b0) * a * self.epoch / self.total_epochs
        self.ratio[:] = 1

        for mb in range(self.total_minibatches):
            profile("train_misc", epoch, nest=True)
            self.amp_context.__enter__()

            shape = self.values.shape
            advantages = torch.zeros(shape, device=device)
            if config.get("per_agent_gamma"):
                advantages = self._grouped_puff_advantage(
                    self.values, self.rewards, self.terminals, self.ratio,
                    advantages, self.row_agent, config,
                )
            else:
                advantages = compute_puff_advantage(
                    self.values,
                    self.rewards,
                    self.terminals,
                    self.ratio,
                    advantages,
                    config["gamma"],
                    config["gae_lambda"],
                    config["vtrace_rho_clip"],
                    config["vtrace_c_clip"],
                )

            profile("train_copy", epoch)
            adv = advantages.abs().sum(axis=1)
            prio_weights = torch.nan_to_num(adv**a, 0, 0, 0)
            prio_probs = (prio_weights + 1e-6) / (prio_weights.sum() + 1e-6)
            idx = torch.multinomial(prio_probs, self.minibatch_segments)
            mb_prio = (self.segments * prio_probs[idx, None]) ** -anneal_beta
            mb_obs = self.observations[idx]
            mb_actions = self.actions[idx]
            mb_logprobs = self.logprobs[idx]
            mb_rewards = self.rewards[idx]
            mb_terminals = self.terminals[idx]
            mb_truncations = self.truncations[idx]
            mb_ratio = self.ratio[idx]
            mb_values = self.values[idx]
            mb_returns = advantages[idx] + mb_values
            mb_advantages = advantages[idx]
            # >>> COGAMES MASK
            # Same prioritized minibatch indices as every other mb_* tensor, so
            # the mask stays aligned with pg/value/entropy terms below.
            mb_mask = self.train_mask[idx]
            # <<< COGAMES MASK

            profile("train_forward", epoch)
            if not config["use_rnn"]:
                mb_obs = mb_obs.reshape(-1, *self.vecenv.single_observation_space.shape)

            state = dict(
                action=mb_actions,
                lstm_h=None,
                lstm_c=None,
            )

            # TODO: Currently only returning traj shaped value as a hack
            logits, newvalue = self.policy(mb_obs, state)
            # TODO: Redundant actions?
            actions, newlogprob, entropy = pufferlib.pytorch.sample_logits(logits, action=mb_actions)

            profile("train_misc", epoch)
            newlogprob = newlogprob.reshape(mb_logprobs.shape)
            logratio = newlogprob - mb_logprobs
            ratio = logratio.exp()
            self.ratio[idx] = ratio.detach()  # TODO: Experiment with this

            # TODO: Only do this if we are KL clipping? Saves 1-2% compute
            with torch.no_grad():
                old_approx_kl = (-logratio).mean()
                approx_kl = ((ratio - 1) - logratio).mean()
                clipfrac = ((ratio - 1.0).abs() > config["clip_coef"]).float().mean()

            # NOTE: upstream recomputed the minibatch advantage here (with the
            # updated ratio) and then immediately discarded it via
            # `adv = mb_advantages` — the kernel launch was pure dead compute
            # (verified: the result tensor was a fancy-index COPY, never read,
            # no side effects, no RNG consumed). Removed; `adv` is exactly what
            # the discard line always made it.
            adv = mb_advantages
            adv = mb_prio * (adv - adv.mean()) / (adv.std() + 1e-8)  # TODO: Norm by full batch
            # adv = mb_prio * (adv - advantages.mean()) / (advantages.std() + 1e-8) # TODO: Norm by full batch

            # >>> COGAMES MASK
            # Masked mean: average only over kept timesteps so dropped
            # (idle-role) transitions contribute zero gradient. Falls back to a
            # plain mean when the whole minibatch is kept (m all ones), which is
            # the default for missions that emit no mask. clamp(min=1.0) guards
            # the degenerate all-dropped minibatch.
            def _masked_mean(x, m):
                m = m.reshape(x.shape)
                return (x * m).sum() / m.sum().clamp(min=1.0)
            # <<< COGAMES MASK

            # Losses
            pg_loss1 = -adv * ratio
            pg_loss2 = -adv * torch.clamp(ratio, 1 - clip_coef, 1 + clip_coef)
            pg_loss = _masked_mean(torch.max(pg_loss1, pg_loss2), mb_mask)

            newvalue = newvalue.view(mb_returns.shape)
            v_clipped = mb_values + torch.clamp(newvalue - mb_values, -vf_clip, vf_clip)
            v_loss_unclipped = (newvalue - mb_returns) ** 2
            v_loss_clipped = (v_clipped - mb_returns) ** 2
            v_loss = 0.5 * _masked_mean(torch.max(v_loss_unclipped, v_loss_clipped), mb_mask)

            entropy_loss = _masked_mean(entropy, mb_mask)

            loss = pg_loss + config["vf_coef"] * v_loss - config["ent_coef"] * entropy_loss
            self.amp_context.__enter__()  # TODO: Debug

            # This breaks vloss clipping?
            self.values[idx] = newvalue.detach().float()

            # Logging. ONE stacked device->host transfer instead of seven
            # .item() calls: on CUDA each .item() is a blocking round-trip
            # that drains the kernel queue, so seven per minibatch serialized
            # the CPU against the GPU. The transferred float32 values are
            # bit-identical to what the individual .item() reads returned.
            profile("train_misc", epoch)
            mb_stats = torch.stack((
                pg_loss, v_loss, entropy_loss,
                old_approx_kl, approx_kl, clipfrac, ratio.mean(),
            )).detach().cpu()
            for key, val in zip(
                ("policy_loss", "value_loss", "entropy", "old_approx_kl",
                 "approx_kl", "clipfrac", "importance"),
                mb_stats,
            ):
                losses[key] += val.item() / self.total_minibatches

            # Learn on accumulated minibatches
            profile("learn", epoch)
            loss.backward()
            if (mb + 1) % self.accumulate_minibatches == 0:
                torch.nn.utils.clip_grad_norm_(self.policy.parameters(), config["max_grad_norm"])
                self.optimizer.step()
                self.optimizer.zero_grad()

        # Reprioritize experience
        profile("train_misc", epoch)
        if config["anneal_lr"]:
            self.scheduler.step()

        y_pred = self.values.flatten()
        y_true = advantages.flatten() + self.values.flatten()
        var_y = y_true.var()
        if var_y == 0:
            explained_var = torch.tensor(float("nan"), device=y_true.device, dtype=var_y.dtype)
        else:
            explained_var = 1 - (y_true - y_pred).var() / var_y
        losses["explained_variance"] = explained_var.item()

        profile.end()
        logs = None
        self.epoch += 1
        done_training = self.global_step >= config["total_timesteps"]
        # >>> COGAMES DDP LOGGING
        # The log branch below runs collectives (dist_sum in mean_and_log /
        # print_dashboard), so under DDP ALL ranks must take it together. The
        # wall-clock gate can disagree across ranks (rank 0 spends extra time
        # printing the dashboard, shifting its 0.25s window) -> mismatched
        # collectives deadlock every rank. Rank 0 decides; everyone follows.
        should_log = done_training or self.global_step == 0 or time.time() > self.last_log_time + 0.25
        if torch.distributed.is_initialized():
            flag = torch.tensor([1.0 if should_log else 0.0], device=config["device"])
            torch.distributed.broadcast(flag, src=0)
            should_log = bool(flag.item())
        # <<< COGAMES DDP LOGGING
        if should_log:
            logs = self.mean_and_log()
            self.losses = losses
            self.print_dashboard()
            self.stats = defaultdict(list)
            self.last_log_time = time.time()
            self.last_log_step = self.global_step
            profile.clear()

        if self.epoch % config["checkpoint_interval"] == 0 or done_training:
            self.save_checkpoint()
            self.msg = f"Checkpoint saved at update {self.epoch}"

        return logs

    def mean_and_log(self):
        config = self.config
        for k in list(self.stats.keys()):
            v = self.stats[k]
            try:
                v = np.mean(v)
            except:
                del self.stats[k]

            self.stats[k] = v

        device = config["device"]
        agent_steps = int(dist_sum(self.global_step, device))
        logs = {
            "SPS": dist_sum(self.sps, device),
            "agent_steps": agent_steps,
            "uptime": time.time() - self.start_time,
            # >>> COGAMES DDP LOGGING
            # Local epoch, NOT dist_sum: ranks advance epochs in lockstep, so the
            # sum was just world_size x epoch — diverging from the dashboard, the
            # checkpoint numbering (model_{epoch}.pt) and non-DDP logs.
            "epoch": int(self.epoch),
            # <<< COGAMES DDP LOGGING
            "learning_rate": self.optimizer.param_groups[0]["lr"],
            **{f"environment/{k}": v for k, v in self.stats.items()},
            **{f"losses/{k}": v for k, v in self.losses.items()},
            **{f"performance/{k}": v["elapsed"] for k, v in self.profile},
            # **{f'environment/{k}': dist_mean(v, device) for k, v in self.stats.items()},
            # **{f'losses/{k}': dist_mean(v, device) for k, v in self.losses.items()},
            # **{f'performance/{k}': dist_sum(v['elapsed'], device) for k, v in self.profile},
        }

        # >>> COGAMES DDP LOGGING
        # Upstream had this inverted: rank 0 returned None WITHOUT logging while
        # the other ranks logged into their no-op loggers — so under DDP nothing
        # ever reached TensorBoard/W&B. Rank 0 must log exactly like a non-DDP
        # run. The dist_sum collectives above already ran on EVERY rank, so the
        # early return on rank != 0 keeps collectives matched.
        if torch.distributed.is_initialized() and torch.distributed.get_rank() != 0:
            return logs
        # <<< COGAMES DDP LOGGING

        self.logger.log(logs, agent_steps)
        return logs

    def close(self):
        self.vecenv.close()
        self.utilization.stop()
        model_path = self.save_checkpoint()
        # >>> COGAMES DDP LOGGING
        # save_checkpoint returns None on DDP ranks != 0 (rank 0 owns the
        # checkpoint files); there is nothing to copy on those ranks.
        if model_path is None:
            return None
        # <<< COGAMES DDP LOGGING
        run_id = self.logger.run_id
        path = os.path.join(self.config["data_dir"], f"{run_id}.pt")
        shutil.copy(model_path, path)
        return path

    def save_checkpoint(self):
        if torch.distributed.is_initialized():
            if torch.distributed.get_rank() != 0:
                return

        run_id = self.logger.run_id
        path = os.path.join(self.config["data_dir"], run_id)
        if not os.path.exists(path):
            os.makedirs(path)

        model_name = f"model_{self.epoch:06d}.pt"
        model_path = os.path.join(path, model_name)
        if os.path.exists(model_path):
            return model_path

        torch.save(self.uncompiled_policy.state_dict(), model_path)

        state = {
            "optimizer_state_dict": self.optimizer.state_dict(),
            "global_step": self.global_step,
            "agent_step": self.global_step,
            "update": self.epoch,
            "model_name": model_name,
            "run_id": run_id,
        }
        state_path = os.path.join(path, "trainer_state.pt")
        torch.save(state, state_path + ".tmp")
        os.rename(state_path + ".tmp", state_path)
        return model_path

    def print_dashboard(self, clear=False, idx=[0], c1="[cyan]", c2="[white]", b1="[bright_cyan]", b2="[bright_white]"):
        config = self.config
        sps = dist_sum(self.sps, config["device"])
        agent_steps = dist_sum(self.global_step, config["device"])
        if torch.distributed.is_initialized():
            if torch.distributed.get_rank() != 0:
                return

        profile = self.profile
        console = Console()
        dashboard = Table(box=rich.box.ROUNDED, expand=True, show_header=False, border_style="bright_cyan")
        table = Table(box=None, expand=True, show_header=False)
        dashboard.add_row(table)

        table.add_column(justify="left", width=30)
        table.add_column(justify="center", width=12)
        table.add_column(justify="center", width=12)
        table.add_column(justify="center", width=13)
        table.add_column(justify="right", width=13)

        table.add_row(
            f"{b1}PufferLib {b2}3.0 {idx[0] * ' '}:blowfish:",
            f"{c1}CPU: {b2}{np.mean(self.utilization.cpu_util):.1f}{c2}%",
            f"{c1}GPU: {b2}{np.mean(self.utilization.gpu_util):.1f}{c2}%",
            f"{c1}DRAM: {b2}{np.mean(self.utilization.cpu_mem):.1f}{c2}%",
            f"{c1}VRAM: {b2}{np.mean(self.utilization.gpu_mem):.1f}{c2}%",
        )
        idx[0] = (idx[0] - 1) % 10

        s = Table(box=None, expand=True)
        remaining = "A hair past a freckle"
        if sps != 0:
            # >>> COGAMES DDP LOGGING
            # `agent_steps` and `sps` are GLOBAL (dist-summed above) but
            # config["total_timesteps"] is each rank's LOCAL budget (the train
            # script splits --steps across ranks). Mixing them made Remaining
            # ~world_size x too short (and negative past 1/world_size of the
            # run). Scale the total back to global for the countdown.
            total_timesteps = config["total_timesteps"]
            if torch.distributed.is_initialized():
                total_timesteps *= torch.distributed.get_world_size()
            remaining = duration((total_timesteps - agent_steps) / sps, b2, c2)
            # <<< COGAMES DDP LOGGING

        s.add_column(f"{c1}Summary", justify="left", vertical="top", width=10)
        s.add_column(f"{c1}Value", justify="right", vertical="top", width=14)
        s.add_row(f"{c2}Env", f"{b2}{config['env']}")
        s.add_row(f"{c2}Params", abbreviate(self.model_size, b2, c2))
        s.add_row(f"{c2}Steps", abbreviate(agent_steps, b2, c2))
        s.add_row(f"{c2}SPS", abbreviate(sps, b2, c2))
        s.add_row(f"{c2}Epoch", f"{b2}{self.epoch}")
        s.add_row(f"{c2}Uptime", duration(self.uptime, b2, c2))
        s.add_row(f"{c2}Remaining", remaining)

        delta = profile.eval["buffer"] + profile.train["buffer"]
        p = Table(box=None, expand=True, show_header=False)
        p.add_column(f"{c1}Performance", justify="left", width=10)
        p.add_column(f"{c1}Time", justify="right", width=8)
        p.add_column(f"{c1}%", justify="right", width=4)
        p.add_row(*fmt_perf("Evaluate", b1, delta, profile.eval, b2, c2))
        p.add_row(*fmt_perf("  Forward", c2, delta, profile.eval_forward, b2, c2))
        p.add_row(*fmt_perf("  Env", c2, delta, profile.env, b2, c2))
        p.add_row(*fmt_perf("  Copy", c2, delta, profile.eval_copy, b2, c2))
        p.add_row(*fmt_perf("  Misc", c2, delta, profile.eval_misc, b2, c2))
        p.add_row(*fmt_perf("Train", b1, delta, profile.train, b2, c2))
        p.add_row(*fmt_perf("  Forward", c2, delta, profile.train_forward, b2, c2))
        p.add_row(*fmt_perf("  Learn", c2, delta, profile.learn, b2, c2))
        p.add_row(*fmt_perf("  Copy", c2, delta, profile.train_copy, b2, c2))
        p.add_row(*fmt_perf("  Misc", c2, delta, profile.train_misc, b2, c2))

        l = Table(
            box=None,
            expand=True,
        )
        l.add_column(f"{c1}Losses", justify="left", width=16)
        l.add_column(f"{c1}Value", justify="right", width=8)
        for metric, value in self.losses.items():
            l.add_row(f"{c2}{metric}", f"{b2}{value:.3f}")

        monitor = Table(box=None, expand=True, pad_edge=False)
        monitor.add_row(s, p, l)
        dashboard.add_row(monitor)

        table = Table(box=None, expand=True, pad_edge=False)
        dashboard.add_row(table)
        left = Table(box=None, expand=True)
        right = Table(box=None, expand=True)
        table.add_row(left, right)
        left.add_column(f"{c1}User Stats", justify="left", width=20)
        left.add_column(f"{c1}Value", justify="right", width=10)
        right.add_column(f"{c1}User Stats", justify="left", width=20)
        right.add_column(f"{c1}Value", justify="right", width=10)
        i = 0

        if self.stats:
            self.last_stats = self.stats

        # do some reordering of self.stats so that important stats are always shown
        prioritized_stats = self._reorder_stats_for_dashboard()

        for metric, value in prioritized_stats:
            try:  # Discard non-numeric values
                int(value)
            except:
                continue

            u = left if i % 2 == 0 else right
            u.add_row(f"{c2}{metric}", f"{b2}{value:.3f}")
            i += 1
            if i == 30:
                break

        if clear:
            console.clear()

        with console.capture() as capture:
            console.print(dashboard)

        print("\033[0;0H" + capture.get())

    def _reorder_stats_for_dashboard(self) -> list[tuple[str, float]]:
        priority_metrics = [
            "agent/heart.gained",
            "agent/avg_reward_per_agent",
            "agent/energy.amount",
            "agent/status.max_steps_without_motion",
            "game/chest.heart.amount",
        ]
        new_stats = []

        stats = self.stats if len(self.stats) > 0 else self.last_stats

        for name in priority_metrics:
            if name in stats:
                new_stats.append((name, stats[name]))

        for name in stats.keys():
            if name not in priority_metrics:
                new_stats.append((name, stats[name]))

        return new_stats


def _grouped_puff_advantage_impl(
    values, rewards, terminals, ratio, advantages, row_agents, config
):
    """Advantage with PER-AGENT gamma: rows are grouped by their agent's gamma
    (config["per_agent_gamma"]: {agent_idx: gamma}, others config["gamma"])
    and the kernel runs once per distinct gamma over that row subset."""
    default_g = float(config["gamma"])
    overrides = {int(k): float(v) for k, v in (config.get("per_agent_gamma") or {}).items()}
    row_gamma = torch.full(
        (values.shape[0],), default_g, device=values.device, dtype=torch.float64
    )
    for aidx, g in overrides.items():
        row_gamma[row_agents == aidx] = g
    for g in torch.unique(row_gamma):
        rows = (row_gamma == g).nonzero(as_tuple=True)[0]
        if rows.numel() == 0:
            continue
        sub_adv = torch.zeros(
            (rows.numel(), values.shape[1]), device=values.device, dtype=advantages.dtype
        )
        sub_adv = compute_puff_advantage(
            values[rows].contiguous(),
            rewards[rows].contiguous(),
            terminals[rows].contiguous(),
            ratio[rows].contiguous(),
            sub_adv,
            float(g),
            config["gae_lambda"],
            config["vtrace_rho_clip"],
            config["vtrace_c_clip"],
        )
        advantages[rows] = sub_adv
    return advantages


def compute_puff_advantage(
    values, rewards, terminals, ratio, advantages, gamma, gae_lambda, vtrace_rho_clip, vtrace_c_clip
):
    """Compute puffer advantage with CPU fallback when the loaded extension lacks a CUDA kernel."""

    if not _C_AVAILABLE:
        raise RuntimeError(
            "Training requires the pufferlib._C extension, which could not be loaded "
            "(likely missing CUDA runtime). Install CUDA torch or build pufferlib-core from source."
        )

    device = values.device
    if not ADVANTAGE_CUDA:
        values = values.cpu()
        rewards = rewards.cpu()
        terminals = terminals.cpu()
        ratio = ratio.cpu()
        advantages = advantages.cpu()

    torch.ops.pufferlib.compute_puff_advantage(
        values, rewards, terminals, ratio, advantages, gamma, gae_lambda, vtrace_rho_clip, vtrace_c_clip
    )

    if not ADVANTAGE_CUDA:
        return advantages.to(device)

    return advantages


def abbreviate(num, b2, c2):
    if num < 1e3:
        return str(num)
    elif num < 1e6:
        return f"{num / 1e3:.1f}K"
    elif num < 1e9:
        return f"{num / 1e6:.1f}M"
    elif num < 1e12:
        return f"{num / 1e9:.1f}B"
    else:
        return f"{num / 1e12:.2f}T"


def duration(seconds, b2, c2):
    seconds = int(seconds)
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    return f"{b2}{h}{c2}h {b2}{m}{c2}m {b2}{s}{c2}s" if h else f"{b2}{m}{c2}m {b2}{s}{c2}s" if m else f"{b2}{s}{c2}s"


def fmt_perf(name, color, delta_ref, prof, b2, c2):
    percent = 0 if delta_ref == 0 else int(100 * prof["buffer"] / delta_ref - 1e-5)
    return f"{color}{name}", duration(prof["elapsed"], b2, c2), f"{b2}{percent:2d}{c2}%"


def dist_sum(value, device):
    if not torch.distributed.is_initialized():
        return value

    tensor = torch.tensor(value, device=device)
    torch.distributed.all_reduce(tensor, op=torch.distributed.ReduceOp.SUM)
    return tensor.item()


def dist_mean(value, device):
    if not torch.distributed.is_initialized():
        return value

    return dist_sum(value, device) / torch.distributed.get_world_size()


class Profile:
    def __init__(self, frequency=5):
        self.profiles = defaultdict(lambda: defaultdict(float))
        self.frequency = frequency
        self.stack = []

    def __iter__(self):
        return iter(self.profiles.items())

    def __getattr__(self, name):
        return self.profiles[name]

    def __call__(self, name, epoch, nest=False):
        if epoch % self.frequency != 0:
            return

        # if torch.cuda.is_available():
        #    torch.cuda.synchronize()

        tick = time.time()
        if len(self.stack) != 0 and not nest:
            self.pop(tick)

        self.stack.append(name)
        self.profiles[name]["start"] = tick

    def pop(self, end):
        profile = self.profiles[self.stack.pop()]
        delta = end - profile["start"]
        profile["elapsed"] += delta
        profile["delta"] += delta

    def end(self):
        # if torch.cuda.is_available():
        #    torch.cuda.synchronize()

        end = time.time()
        for i in range(len(self.stack)):
            self.pop(end)

    def clear(self):
        for prof in self.profiles.values():
            if prof["delta"] > 0:
                prof["buffer"] = prof["delta"]
                prof["delta"] = 0


class Utilization(Thread):
    def __init__(self, delay=1, maxlen=20):
        super().__init__()
        self.cpu_mem = deque([0], maxlen=maxlen)
        self.cpu_util = deque([0], maxlen=maxlen)
        self.gpu_util = deque([0], maxlen=maxlen)
        self.gpu_mem = deque([0], maxlen=maxlen)
        self.stopped = False
        self.delay = delay
        self.start()

    def run(self):
        while not self.stopped:
            self.cpu_util.append(100 * psutil.cpu_percent() / psutil.cpu_count())
            mem = psutil.virtual_memory()
            self.cpu_mem.append(100 * mem.active / mem.total)
            if torch.cuda.is_available():
                # Monitoring in distributed crashes nvml
                if torch.distributed.is_initialized():
                    time.sleep(self.delay)
                    continue

                self.gpu_util.append(torch.cuda.utilization())
                free, total = torch.cuda.mem_get_info()
                self.gpu_mem.append(100 * (total - free) / total)
            else:
                self.gpu_util.append(0)
                self.gpu_mem.append(0)

            time.sleep(self.delay)

    def stop(self):
        self.stopped = True


def downsample(arr, m):
    if len(arr) < m:
        return arr

    if m == 0:
        return [arr[-1]]

    orig_arr = arr
    last = arr[-1]
    arr = arr[:-1]
    arr = np.array(arr)
    n = len(arr)
    n = (n // m) * m
    arr = arr[-n:]
    downsampled = arr.reshape(m, -1).mean(axis=1)
    return np.concatenate([downsampled, [last]])


class NoLogger:
    def __init__(self, args):
        self.run_id = str(int(100 * time.time()))

    def log(self, logs, step):
        pass

    def close(self, model_path):
        pass


class NeptuneLogger:
    def __init__(self, args, load_id=None, mode="async"):
        import neptune as nept

        neptune_name = args["neptune_name"]
        neptune_project = args["neptune_project"]
        neptune = nept.init_run(
            project=f"{neptune_name}/{neptune_project}",
            capture_hardware_metrics=False,
            capture_stdout=False,
            capture_stderr=False,
            capture_traceback=False,
            with_id=load_id,
            mode=mode,
            tags=[args["tag"]] if args["tag"] is not None else [],
        )
        self.run_id = neptune._sys_id
        self.neptune = neptune
        for k, v in pufferlib.unroll_nested_dict(args):
            neptune[k].append(v)

    def log(self, logs, step):
        for k, v in logs.items():
            self.neptune[k].append(v, step=step)

    def close(self, model_path):
        self.neptune["model"].track_files(model_path)
        self.neptune.stop()

    def download(self):
        self.neptune["model"].download(destination="artifacts")
        return f"artifacts/{self.run_id}.pt"


class WandbLogger:
    def __init__(self, args, load_id=None, resume="allow"):
        import wandb

        wandb.init(
            id=load_id or wandb.util.generate_id(),
            project=args["wandb_project"],
            group=args["wandb_group"],
            allow_val_change=True,
            save_code=False,
            resume=resume,
            config=args,
            tags=[args["tag"]] if args["tag"] is not None else [],
        )
        self.wandb = wandb
        self.run_id = wandb.run.id

    def log(self, logs, step):
        self.wandb.log(logs, step=step)

    def close(self, model_path):
        artifact = self.wandb.Artifact(self.run_id, type="model")
        artifact.add_file(model_path)
        self.wandb.run.log_artifact(artifact)
        self.wandb.finish()

    def download(self):
        artifact = self.wandb.use_artifact(f"{self.run_id}:latest")
        data_dir = artifact.download()
        model_file = max(os.listdir(data_dir))
        return f"{data_dir}/{model_file}"


def train(env_name, args=None, vecenv=None, policy=None, logger=None):
    args = args or load_config(env_name)
    vecenv = vecenv or load_env(env_name, args)
    policy = policy or load_policy(args, vecenv)

    # Assume TorchRun DDP is used if LOCAL_RANK is set
    if "LOCAL_RANK" in os.environ:
        world_size = int(os.environ.get("WORLD_SIZE", 1))
        print("World size", world_size)
        master_addr = os.environ.get("MASTER_ADDR", "localhost")
        master_port = os.environ.get("MASTER_PORT", "29500")
        local_rank = int(os.environ["LOCAL_RANK"])
        print(f"rank: {local_rank}, MASTER_ADDR={master_addr}, MASTER_PORT={master_port}")
        torch.cuda.set_device(local_rank)
        args["train"]["device"] = torch.cuda.current_device()
        torch.distributed.init_process_group(backend="nccl", world_size=world_size)
        policy = policy.to(local_rank)
        model = torch.nn.parallel.DistributedDataParallel(policy, device_ids=[local_rank], output_device=local_rank)
        if hasattr(policy, "lstm"):
            # model.lstm = policy.lstm
            model.hidden_size = policy.hidden_size

        model.forward_eval = policy.forward_eval
        policy = model.to(local_rank)

    if args["neptune"]:
        logger = NeptuneLogger(args)
    elif args["wandb"]:
        logger = WandbLogger(args)

    train_config = dict(**args["train"], env=env_name)
    pufferl = PuffeRL(train_config, vecenv, policy, logger)

    all_logs = []
    while pufferl.global_step < train_config["total_timesteps"]:
        pufferl.evaluate()
        logs = pufferl.train()

        if logs is not None:
            if pufferl.global_step > 0.20 * train_config["total_timesteps"]:
                all_logs.append(logs)

    # Final eval. You can reset the env here, but depending on
    # your env, this can skew data (i.e. you only collect the shortest
    # rollouts within a fixed number of epochs)
    i = 0
    stats = {}
    while i < 32 or not stats:
        stats = pufferl.evaluate()
        i += 1

    logs = pufferl.mean_and_log()
    if logs is not None:
        all_logs.append(logs)

    pufferl.print_dashboard()
    model_path = pufferl.close()
    pufferl.logger.close(model_path)
    return all_logs


def eval(env_name, args=None, vecenv=None, policy=None):
    args = args or load_config(env_name)
    args["vec"] = dict(backend="Serial", num_envs=1)
    vecenv = vecenv or load_env(env_name, args)
    if not isinstance(vecenv, pufferlib.vector.Serial):
        raise pufferlib.APIUsageError("eval requires Serial vector env")

    policy = policy or load_policy(args, vecenv)
    ob, info = vecenv.reset()
    driver = vecenv.driver_env
    num_agents = vecenv.observation_space.shape[0]
    device = args["train"]["device"]

    state = {}
    if args["train"]["use_rnn"]:
        state = dict(
            lstm_h=torch.zeros(num_agents, policy.hidden_size, device=device),
            lstm_c=torch.zeros(num_agents, policy.hidden_size, device=device),
        )

    frames = []
    while True:
        render = driver.render()
        if len(frames) < args["save_frames"]:
            frames.append(render)

        # Screenshot Ocean envs with F12, gifs with control + F12
        if driver.render_mode == "ansi":
            print("\033[0;0H" + render + "\n")
            time.sleep(1 / args["fps"])
        elif driver.render_mode == "rgb_array":
            import cv2

            render = cv2.cvtColor(render, cv2.COLOR_RGB2BGR)
            cv2.imshow("frame", render)
            cv2.waitKey(1)
            time.sleep(1 / args["fps"])

        with torch.no_grad():
            ob = torch.as_tensor(ob).to(device)
            logits, value = policy.forward_eval(ob, state)
            action, logprob, _ = pufferlib.pytorch.sample_logits(logits)
            action = action.cpu().numpy().reshape(vecenv.action_space.shape)

        if isinstance(logits, torch.distributions.Normal):
            action = np.clip(action, vecenv.action_space.low, vecenv.action_space.high)

        ob = vecenv.step(action)[0]

        if len(frames) > 0 and len(frames) == args["save_frames"]:
            import imageio

            imageio.mimsave(args["gif_path"], frames, fps=args["fps"], loop=0)
            frames.append("Done")


def sweep(args=None, env_name=None):
    args = args or load_config(env_name)
    if not args["wandb"] and not args["neptune"]:
        raise pufferlib.APIUsageError("Sweeps require either wandb or neptune")

    method = args["sweep"].pop("method")
    try:
        sweep_cls = getattr(pufferlib.sweep, method)
    except:
        raise pufferlib.APIUsageError(f"Invalid sweep method {method}. See pufferlib.sweep")

    sweep = sweep_cls(args["sweep"])
    points_per_run = args["sweep"]["downsample"]
    target_key = f"environment/{args['sweep']['metric']}"
    for i in range(args["max_runs"]):
        seed = time.time_ns() & 0xFFFFFFFF
        random.seed(seed)
        np.random.seed(seed)
        torch.manual_seed(seed)
        sweep.suggest(args)
        total_timesteps = args["train"]["total_timesteps"]
        all_logs = train(env_name, args=args)
        all_logs = [e for e in all_logs if target_key in e]
        scores = downsample([log[target_key] for log in all_logs], points_per_run)
        costs = downsample([log["uptime"] for log in all_logs], points_per_run)
        timesteps = downsample([log["agent_steps"] for log in all_logs], points_per_run)
        for score, cost, timestep in zip(scores, costs, timesteps, strict=False):
            args["train"]["total_timesteps"] = timestep
            sweep.observe(args, score, cost)

        # Prevent logging final eval steps as training steps
        args["train"]["total_timesteps"] = total_timesteps


def profile(args=None, env_name=None, vecenv=None, policy=None):
    args = load_config()
    vecenv = vecenv or load_env(env_name, args)
    policy = policy or load_policy(args, vecenv)

    train_config = dict(**args["train"], env=args["env_name"], tag=args["tag"])
    pufferl = PuffeRL(train_config, vecenv, policy, neptune=args["neptune"], wandb=args["wandb"])

    from torch.profiler import ProfilerActivity, profile, record_function

    with profile(activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA], record_shapes=True) as prof:
        with record_function("model_inference"):
            for _ in range(10):
                stats = pufferl.evaluate()
                pufferl.train()

    print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=10))
    prof.export_chrome_trace("trace.json")


def export(args=None, env_name=None, vecenv=None, policy=None):
    args = args or load_config(env_name)
    vecenv = vecenv or load_env(env_name, args)
    policy = policy or load_policy(args, vecenv)

    weights = []
    for name, param in policy.named_parameters():
        weights.append(param.data.cpu().numpy().flatten())
        print(name, param.shape, param.data.cpu().numpy().ravel()[0])

    path = f"{args['env_name']}_weights.bin"
    weights = np.concatenate(weights)
    weights.tofile(path)
    print(f"Saved {len(weights)} weights to {path}")


def autotune(args=None, env_name=None, vecenv=None, policy=None):
    package = args["package"]
    module_name = "pufferlib.ocean" if package == "ocean" else f"pufferlib.environments.{package}"
    env_module = importlib.import_module(module_name)
    env_name = args["env_name"]
    make_env = env_module.env_creator(env_name)
    pufferlib.vector.autotune(make_env, batch_size=args["train"]["env_batch_size"])


def load_env(env_name, args):
    package = args["package"]
    module_name = "pufferlib.ocean" if package == "ocean" else f"pufferlib.environments.{package}"
    env_module = importlib.import_module(module_name)
    make_env = env_module.env_creator(env_name)
    return pufferlib.vector.make(make_env, env_kwargs=args["env"], **args["vec"])


def load_policy(args, vecenv):
    package = args["package"]
    module_name = "pufferlib.ocean" if package == "ocean" else f"pufferlib.environments.{package}"
    env_module = importlib.import_module(module_name)

    device = args["train"]["device"]
    policy_cls = getattr(env_module.torch, args["policy_name"])
    policy = policy_cls(vecenv.driver_env, **args["policy"])

    rnn_name = args["rnn_name"]
    if rnn_name is not None:
        rnn_cls = getattr(env_module.torch, args["rnn_name"])
        policy = rnn_cls(vecenv.driver_env, policy, **args["rnn"])

    policy = policy.to(device)

    load_id = args["load_id"]
    if load_id is not None:
        if args["mode"] not in ("train", "eval"):
            raise pufferlib.APIUsageError("load_id requires mode to be train or eval")

        if args["neptune"]:
            path = NeptuneLogger(args, load_id, mode="read-only").download()
        elif args["wandb"]:
            path = WandbLogger(args, load_id).download()
        else:
            raise pufferlib.APIUsageError("No run id provided for eval")

        state_dict = torch.load(path, map_location=device)
        state_dict = {k.replace("module.", ""): v for k, v in state_dict.items()}
        policy.load_state_dict(torch.load(path, map_location=device))

    load_path = args["load_model_path"]
    if load_path == "latest":
        load_path = max(glob.glob("experiments/*.pt"), key=os.path.getctime)

    if load_path is not None:
        state_dict = torch.load(load_path, map_location=device)
        state_dict = {k.replace("module.", ""): v for k, v in state_dict.items()}
        policy.load_state_dict(state_dict)
        # state_path = os.path.join(*load_path.split('/')[:-1], 'state.pt')
        # optim_state = torch.load(state_path)['optimizer_state_dict']
        # pufferl.optimizer.load_state_dict(optim_state)

    return policy


def load_config(env_name):
    parser = argparse.ArgumentParser(
        description=f":blowfish: PufferLib [bright_cyan]{pufferlib.__version__}[/]"
        " demo options. Shows valid args for your env and policy",
        formatter_class=RichHelpFormatter,
        add_help=False,
    )
    parser.add_argument("--load-model-path", type=str, default=None, help="Path to a pretrained checkpoint")
    parser.add_argument(
        "--load-id", type=str, default=None, help="Kickstart/eval from from a finished Wandb/Neptune run"
    )
    parser.add_argument(
        "--render-mode", type=str, default="auto", choices=["auto", "human", "ansi", "rgb_array", "raylib", "None"]
    )
    parser.add_argument("--save-frames", type=int, default=0)
    parser.add_argument("--gif-path", type=str, default="eval.gif")
    parser.add_argument("--fps", type=float, default=15)
    parser.add_argument("--max-runs", type=int, default=200, help="Max number of sweep runs")
    parser.add_argument("--wandb", action="store_true", help="Use wandb for logging")
    parser.add_argument("--wandb-project", type=str, default="pufferlib")
    parser.add_argument("--wandb-group", type=str, default="debug")
    parser.add_argument("--neptune", action="store_true", help="Use neptune for logging")
    parser.add_argument("--neptune-name", type=str, default="pufferai")
    parser.add_argument("--neptune-project", type=str, default="ablations")
    parser.add_argument("--local-rank", type=int, default=0, help="Used by torchrun for DDP")
    parser.add_argument("--tag", type=str, default=None, help="Tag for experiment")
    args = parser.parse_known_args()[0]

    # Load defaults and config
    puffer_dir = os.path.dirname(os.path.realpath(__file__))
    puffer_config_dir = os.path.join(puffer_dir, "config/**/*.ini")
    puffer_default_config = os.path.join(puffer_dir, "config/default.ini")
    if env_name == "default":
        p = configparser.ConfigParser()
        p.read(puffer_default_config)
    else:
        for path in glob.glob(puffer_config_dir, recursive=True):
            p = configparser.ConfigParser()
            p.read([puffer_default_config, path])
            if env_name in p["base"]["env_name"].split():
                break
        else:
            raise pufferlib.APIUsageError("No config for env_name {}".format(env_name))

    # Dynamic help menu from config
    def auto_type(value):
        """Type inference for numeric args that use 'auto' as a default value"""
        if value == "auto":
            return value
        if value.isnumeric():
            return int(value)
        return float(value)

    for section in p.sections():
        for key in p[section]:
            try:
                value = ast.literal_eval(p[section][key])
            except:
                value = p[section][key]

            fmt = f"--{key}" if section == "base" else f"--{section}.{key}"
            parser.add_argument(
                fmt.replace("_", "-"), default=value, type=auto_type if value == "auto" else type(value)
            )

    parser.add_argument(
        "-h", "--help", default=argparse.SUPPRESS, action="help", help="Show this help message and exit"
    )

    # Unpack to nested dict
    parsed = vars(parser.parse_args())
    args = defaultdict(dict)
    for key, value in parsed.items():
        next = args
        for subkey in key.split("."):
            prev = next
            next = next.setdefault(subkey, {})

        prev[subkey] = value

    args["train"]["use_rnn"] = args["rnn_name"] is not None
    # args['train']['env'] = env_name
    # args['env_name'] = env_name
    return args


def main():
    err = (
        "Usage: puffer [train, eval, sweep, autotune, profile, export] [env_name] [optional args]. --help for more info"
    )
    if len(sys.argv) < 3:
        raise pufferlib.APIUsageError(err)

    mode = sys.argv.pop(1)
    env_name = sys.argv.pop(1)
    if mode == "train":
        train(env_name=env_name)
    elif mode == "eval":
        eval(env_name=env_name)
    elif mode == "sweep":
        sweep(env_name=env_name)
    elif mode == "autotune":
        autotune(env_name=env_name)
    elif mode == "profile":
        profile(env_name=env_name)
    elif mode == "export":
        export(env_name=env_name)
    else:
        raise pufferlib.APIUsageError(err)


if __name__ == "__main__":
    main()
