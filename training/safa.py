"""Safa FourScore role curriculum over the frozen Polyworld simulation."""
import ctypes
from pathlib import Path

import gymnasium
import numpy as np
import pufferlib
import torch

from environment import Environment
from fourscore.network import TutorialPolicyNet, load_contract

SOURCE = ('https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/'
          'ba2cbbace118369d405d3087febec62adc73dee9/')
# Columns: miner/aligner/scrambler gear deltas, C/O/G/S gains, align, scramble,
# hearts lost. The active source recipe samples generalist (3) and idle (4).
WEIGHTS = np.zeros((10, 10), np.float32)
WEIGHTS[3] = [1, 1, 1, .005, .005, .005, .005, 1, 1, -.1]
ACTION_MAP = np.array([0, 1, 3, 4, 2], np.int32)
PPO = dict(learning_rate=.0001, gamma=.99, gae_lambda=.90,
           update_epochs=1, clip_coef=.2, vf_coef=.5, vf_clip_coef=.2,
           max_grad_norm=1., ent_coef=.03, adam_beta1=.95, adam_beta2=.999,
           anneal_lr=False, vtrace_rho_clip=1., vtrace_c_clip=1.,
           prio_alpha=.8, prio_beta0=.2, min_lr_ratio=0.)


def assign_roles(rng, matches):
    """Guarantee one generalist per team and sample the other seven slots."""
    roles = rng.choice(np.array([3, 4], np.int32), (matches, 4, 8))
    roles[:, :, 0] = 3
    for team in roles.reshape(-1, 8):
        rng.shuffle(team)
    return roles.reshape(-1)


class SafaEnvironment(pufferlib.PufferEnv):
    def __init__(self, library, matches=1, max_ticks=10000, buf=None):
        self.native = Environment(library, matches, max_ticks)
        self.num_agents = matches * 32
        self.agents_per_batch = self.num_agents
        self.matches = matches
        self.single_observation_space = gymnasium.spaces.Box(
            -np.inf, np.inf, (135, 13, 13), np.float32)
        self.single_action_space = gymnasium.spaces.Discrete(5)
        super().__init__(buf)
        self.roles = np.zeros(self.num_agents, np.int32)
        self.events = np.zeros((self.num_agents, 10), np.float32)
        self.grid = np.zeros((self.num_agents, 134, 13, 13), np.float32)
        self.event_totals = np.zeros(10, np.float64)
        self.total_reward = 0.
        lib = self.native.library
        floats = np.ctypeslib.ndpointer(dtype=np.float32, flags='C_CONTIGUOUS')
        integers = np.ctypeslib.ndpointer(dtype=np.int32, flags='C_CONTIGUOUS')
        lib.cvc_safa_events.argtypes = [ctypes.c_void_p, floats]
        lib.cvc_safa_events.restype = ctypes.c_int
        lib.cvc_safa_observe.argtypes = [ctypes.c_void_p, integers, floats]
        lib.cvc_safa_observe.restype = ctypes.c_int

    def observe(self):
        """Expose real sampled roles and a training-only recurrent reset flag."""
        self.native._check(self.native.library.cvc_safa_observe(
            self.native.handle, self.roles, self.grid))
        self.observations[:, :134] = self.grid
        self.observations[:, 134] = 0
        self.observations[:, 134, 0, 0] = self.terminals

    def info(self):
        """Associate loss masks with the observation just returned to PuffeRL."""
        return [dict(_cogames_train_mask=(self.roles != 4).astype(np.float32))]

    def reset(self, seed=None):
        seed = 42 if seed is None else int(seed)
        self.rng = np.random.default_rng(seed)
        self.roles[:] = assign_roles(self.rng, self.matches)
        self.native.reset(seed)
        self.rewards.fill(0)
        self.terminals.fill(False)
        self.truncations.fill(False)
        self.event_totals.fill(0)
        self.total_reward = 0
        self.observe()
        return self.observations, self.info()

    def step(self, actions):
        """Randomize idle seats, apply source rewards, and renew completed roles."""
        actions = np.asarray(actions)
        if actions.shape != (self.num_agents,) or actions.dtype.kind not in 'iu':
            raise ValueError('Expected one integer legacy action per cog')
        if np.any(actions < 0) or np.any(actions > 4):
            raise ValueError('Action outside 0 .. 4')
        native_actions = ACTION_MAP[actions].copy()
        idle = self.roles == 4
        native_actions[idle] = self.rng.integers(0, 5, idle.sum(), dtype=np.int32)
        _, _, done, _, _ = self.native.step(native_actions)
        self.native._check(self.native.library.cvc_safa_events(
            self.native.handle, self.events))
        self.rewards[:] = (self.events * WEIGHTS[self.roles]).sum(axis=1)
        self.event_totals += self.events[~idle].sum(axis=0)
        self.total_reward += float(self.rewards.sum())
        self.terminals[:] = done
        for lane in range(self.matches):
            start = lane * 32
            if done[start]:
                self.roles[start:start + 32] = assign_roles(self.rng, 1)
        self.observe()
        return self.observations, self.rewards, self.terminals, self.truncations, self.info()

    def close(self):
        self.native.close()


class SafaPolicy(TutorialPolicyNet):
    def __init__(self):
        contract = load_contract(Path(__file__).parent / 'fourscore/safa_candidate.json')
        from types import SimpleNamespace
        contract.obs_features = [SimpleNamespace(**f) for f in contract.obs_features]
        super().__init__(contract)

    def forward(self, observations, state=None):
        """Consume dense native grids with the source CNN, center encoder and LSTM."""
        if observations.ndim == 5:
            batch, horizon = observations.shape[:2]
        else:
            batch, horizon = len(observations), 1
        observations = observations.reshape(batch * horizon, 135, 13, 13)
        grid = observations[:, :134]
        resets = observations[:, 134, 0, 0].reshape(batch, horizon).bool()
        encoded = torch.cat((torch.relu(self._cnn_fc(self._cnn(grid))),
                             torch.relu(self._self_encoder(grid[:, :, 6, 6]))), dim=-1)
        encoded = encoded.reshape(batch, horizon, 512)
        memory = self._parse_state(state)
        if resets.any():
            if memory is None:
                memory = (encoded.new_zeros(1, batch, 512),
                          encoded.new_zeros(1, batch, 512))
            outputs = []
            for tick in range(horizon):
                keep = (~resets[:, tick])[None, :, None]
                memory = tuple(value * keep for value in memory)
                output, memory = self._rnn(encoded[:, tick:tick + 1], memory)
                outputs.append(output)
            hidden = torch.cat(outputs, dim=1)
        else:
            hidden, memory = self._rnn(encoded, memory)
        if isinstance(state, dict):
            state['lstm_h'], state['lstm_c'] = [value.squeeze(0) for value in memory]
        hidden = hidden.reshape(batch * horizon, 512)
        return self._action_head(hidden), self._value_head(hidden)
