"""PufferLib native shared-buffer adapter for frozen FourScore."""
import ctypes
from pathlib import Path
import threading

import gymnasium
import numpy as np
import pufferlib


class Stats(ctypes.Structure):
    _fields_ = [(name, ctypes.c_int64) for name in
               ('episodes', 'ticks', 'score', 'gathered', 'deposited', 'captured')]


class Environment(pufferlib.PufferEnv):
    def __init__(self, library, matches=4, max_ticks=10000, buf=None):
        self.owner = threading.get_ident()
        self.library = ctypes.CDLL(str(Path(library).resolve()))
        lib = self.library
        lib.cvc_abi.restype = ctypes.c_int
        if lib.cvc_abi() != 1:
            raise ValueError('Unsupported CVC training ABI')
        lib.cvc_tokens.restype = ctypes.c_int
        lib.cvc_error.restype = ctypes.c_char_p
        lib.cvc_create.argtypes = [ctypes.c_int, ctypes.c_int]
        lib.cvc_create.restype = ctypes.c_void_p
        bytes_ = np.ctypeslib.ndpointer(dtype=np.uint8, flags='C_CONTIGUOUS')
        floats = np.ctypeslib.ndpointer(dtype=np.float32, flags='C_CONTIGUOUS')
        actions = np.ctypeslib.ndpointer(dtype=np.int32, flags='C_CONTIGUOUS')
        bools = np.ctypeslib.ndpointer(dtype=np.bool_, flags='C_CONTIGUOUS')
        lib.cvc_reset.argtypes = [ctypes.c_void_p, ctypes.c_int32, bytes_]
        lib.cvc_reset.restype = ctypes.c_int
        lib.cvc_step.argtypes = [ctypes.c_void_p, actions, bytes_, floats,
                                bools, ctypes.POINTER(Stats)]
        lib.cvc_step.restype = ctypes.c_int
        lib.cvc_close.argtypes = [ctypes.c_void_p]
        lib.cvc_close.restype = None
        lib.cvc_hash.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.cvc_hash.restype = ctypes.c_uint64
        self.matches = matches
        self.num_agents = matches * 32
        self.agents_per_batch = self.num_agents
        self.single_observation_space = gymnasium.spaces.Box(
            0, 255, (lib.cvc_tokens(), 3), np.uint8)
        self.single_action_space = gymnasium.spaces.Discrete(5)
        super().__init__(buf)
        self.handle = lib.cvc_create(matches, max_ticks)
        if not self.handle:
            raise ValueError(lib.cvc_error().decode())
        self.stats = Stats()
        self.total_reward = 0.0

    def _check(self, result=0):
        if threading.get_ident() != self.owner:
            raise RuntimeError('Use one owning thread for the Nim environment')
        if result != 0:
            raise ValueError(self.library.cvc_error().decode())
        if not self.handle:
            raise RuntimeError('Environment is closed')

    def reset(self, seed=None):
        self._check()
        self._check(self.library.cvc_reset(
            self.handle, 1 if seed is None else int(seed), self.observations))
        self.rewards.fill(0)
        self.terminals.fill(False)
        self.truncations.fill(False)
        self.stats = Stats()
        self.total_reward = 0.0
        return self.observations, []

    def step(self, actions):
        self._check()
        actions = np.asarray(actions)
        if actions.shape != (self.num_agents,) or not np.issubdtype(actions.dtype, np.integer):
            raise ValueError('Expected one integer action per cog')
        if np.any(actions < 0) or np.any(actions > 4):
            raise ValueError('Actions must be in 0 .. 4')
        before = self.stats.episodes
        self._check(self.library.cvc_step(
            self.handle, np.ascontiguousarray(actions, dtype=np.int32),
            self.observations, self.rewards, self.terminals,
            ctypes.byref(self.stats)))
        self.total_reward += float(self.rewards.sum())
        infos = []
        if self.stats.episodes != before:
            infos = [dict(score=self.stats.score / self.stats.episodes,
                          episodes=self.stats.episodes)]
        return self.observations, self.rewards, self.terminals, self.truncations, infos

    def close(self):
        if self.handle:
            self._check()
            self.library.cvc_close(self.handle)
            self.handle = None
