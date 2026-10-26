"""Small sparse-token baseline policy for PufferLib PPO."""
import torch
from torch import nn


class Policy(nn.Module):
    def __init__(self, tokens=2048, hidden=64):
        super().__init__()
        self.encoder = nn.Sequential(nn.Linear(tokens * 3, hidden), nn.Tanh(),
                                     nn.Linear(hidden, hidden), nn.Tanh())
        self.actor = nn.Linear(hidden, 5)
        self.critic = nn.Linear(hidden, 1)
        nn.init.orthogonal_(self.actor.weight, 0.01)
        nn.init.zeros_(self.actor.bias)

    def forward(self, observations, state=None):
        # Padding maps to zero; valid location 0xFE remains distinguishable.
        features = (255 - observations.float()).flatten(1) / 255
        hidden = self.encoder(features)
        return self.actor(hidden), self.critic(hidden)

    def forward_eval(self, observations, state=None):
        return self.forward(observations, state)
