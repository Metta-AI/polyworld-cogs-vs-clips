"""Metta AI tutorial CNN/LSTM port; see LICENSE and docs/safa-curriculum.md."""
from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Optional, Union

import torch
from torch import nn


def coordinates(observations, dtype):
    """Decode the original packed coordinates, including global tokens."""
    locations = observations[..., 0].to(dtype)
    return locations & 15, locations >> 4


def load_contract(path):
    """Load the exact checkpoint's observation metadata."""
    with open(path) as source:
        data = json.load(source)
    return SimpleNamespace(
        **data, obs_height=data['egocentric_shape'][0],
        obs_width=data['egocentric_shape'][1])


def network(contract, checkpoint=None, zero_reward=False):
    """Build a network, strictly loading tensor-only checkpoint weights."""
    info = SimpleNamespace(**vars(contract))
    info.obs_features = [SimpleNamespace(**f) for f in contract.obs_features]
    model = TutorialPolicyNet(info, zero_reward=zero_reward)
    if checkpoint is not None:
        weights = torch.load(checkpoint, map_location='cpu', weights_only=True)
        model.load_state_dict(weights, strict=True)
    return model.eval()


class TutorialPolicyNet(nn.Module):
    """Standard CNN + LSTM network."""

    _feature_scale: torch.Tensor

    def __init__(self, policy_env_info, zero_reward=False):
        super().__init__()

        self.hidden_size = 512
        self._obs_height = policy_env_info.obs_height
        self._obs_width = policy_env_info.obs_width
        self._num_features = max((int(f.id) for f in policy_env_info.obs_features), default=0) + 1

        # Feature normalization
        feature_norms = {f.id: f.normalization for f in policy_env_info.obs_features}
        max_id = max((int(fid) for fid in feature_norms), default=-1)
        feature_scale = torch.ones(max(256, max_id + 1), dtype=torch.float32)
        for fid, norm in feature_norms.items():
            feature_scale[fid] = max(float(norm), 1.0)
        self.register_buffer("_feature_scale", feature_scale)

        if zero_reward:
            mask = torch.zeros_like(feature_scale)
            for feature in policy_env_info.obs_features:
                if feature.name == 'last_reward':
                    mask[feature.id] = 1
            self.register_buffer('_zero_feature_mask', mask)

        # CNN encoder (standard 3x3 convs with stride 2), with GroupNorm for
        # training stability under the non-stationary reward signal introduced
        # by mid-episode role switching.
        self._cnn = nn.Sequential(
            nn.Conv2d(self._num_features, 64, kernel_size=3, stride=2, padding=1),
            nn.GroupNorm(1, 64),
            nn.ReLU(),
            nn.Conv2d(64, 128, kernel_size=3, stride=2, padding=1),
            nn.GroupNorm(1, 128),
            nn.ReLU(),
            nn.Flatten(),
        )

        with torch.no_grad():
            dummy = torch.zeros(1, self._num_features, self._obs_height, self._obs_width)
            cnn_out_size = self._cnn(dummy).shape[1]

        self._cnn_fc = nn.Linear(cnn_out_size, 256)
        self._self_encoder = nn.Linear(self._num_features, 256)
        self._rnn = nn.LSTM(self.hidden_size, self.hidden_size, num_layers=1, batch_first=True)

        # Output heads
        num_actions = len(policy_env_info.action_names)
        self._action_head = nn.Linear(self.hidden_size, num_actions)
        self._value_head = nn.Linear(self.hidden_size, 1)

    def _tokens_to_grid(self, observations: torch.Tensor) -> torch.Tensor:
        """Convert token observations [B, T, 3] to grid [B, C, H, W]."""
        batch_size = observations.shape[0]
        device = observations.device

        x_coords, y_coords = coordinates(observations, torch.long)
        feature_ids = observations[..., 1].to(torch.long)
        values = observations[..., 2].to(torch.float32)

        valid_mask = observations[..., 0] != 0xFF
        x_coords = torch.clamp(x_coords, 0, self._obs_width - 1)
        y_coords = torch.clamp(y_coords, 0, self._obs_height - 1)
        feature_ids_clamped = torch.clamp(feature_ids, 0, self._num_features - 1)

        fid_clamped_scale = torch.clamp(feature_ids, 0, self._feature_scale.shape[0] - 1)
        scale = self._feature_scale[fid_clamped_scale]
        values = (values / (scale + 1e-6)) * valid_mask.float()

        if hasattr(self, '_zero_feature_mask'):
            values = values * (1 - self._zero_feature_mask[fid_clamped_scale])

        grid = torch.zeros(batch_size, self._num_features, self._obs_height, self._obs_width, device=device)
        batch_idx = torch.arange(batch_size, device=device).unsqueeze(1).expand_as(x_coords)
        linear_idx = (
            batch_idx * (self._num_features * self._obs_height * self._obs_width)
            + feature_ids_clamped * (self._obs_height * self._obs_width)
            + y_coords * self._obs_width
            + x_coords
        )
        grid.view(-1).scatter_add_(0, linear_idx.view(-1), values.view(-1))
        return grid

    def forward(
        self,
        observations: torch.Tensor,
        state: Optional[Union[tuple[torch.Tensor, torch.Tensor], dict[str, torch.Tensor]]] = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass: observations [B, T, 3] or [B, S, T, 3] -> (logits, values)."""
        orig_shape = observations.shape

        if observations.dim() == 4:
            segments, bptt_horizon = orig_shape[0], orig_shape[1]
            observations = observations.reshape(segments * bptt_horizon, *orig_shape[2:])
        else:
            segments, bptt_horizon = orig_shape[0], 1

        # CNN encoder
        grid = self._tokens_to_grid(observations)
        cnn_out = torch.relu(self._cnn_fc(self._cnn(grid)))

        # Center features (agent's own state)
        center = grid[:, :, self._obs_height // 2, self._obs_width // 2]
        self_out = torch.relu(self._self_encoder(center))

        hidden = torch.cat([cnn_out, self_out], dim=-1)
        hidden = hidden.reshape(segments, bptt_horizon, -1)

        # LSTM
        rnn_state = self._parse_state(state)
        hidden, new_state = self._rnn(hidden, rnn_state)

        if isinstance(state, dict) and "lstm_h" in state:
            h, c = new_state
            state["lstm_h"] = h.transpose(0, 1) if h.dim() == 3 else h
            state["lstm_c"] = c.transpose(0, 1) if c.dim() == 3 else c

        hidden = hidden.reshape(segments * bptt_horizon, -1)
        return self._action_head(hidden), self._value_head(hidden)

    def forward_eval(
        self,
        observations: torch.Tensor,
        state: Optional[Union[tuple[torch.Tensor, torch.Tensor], dict[str, torch.Tensor]]] = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass for evaluation (same as forward)."""
        return self.forward(observations, state)

    def _parse_state(
        self,
        state: Optional[Union[tuple[torch.Tensor, torch.Tensor], dict[str, torch.Tensor]]],
    ) -> Optional[tuple[torch.Tensor, torch.Tensor]]:
        """Parse LSTM state from various formats."""
        if state is None:
            return None

        if isinstance(state, dict):
            h, c = state.get("lstm_h"), state.get("lstm_c")
            if h is None or c is None:
                return None
        else:
            h, c = state

        if h.dim() == 3:
            h, c = h.transpose(0, 1), c.transpose(0, 1)
        elif h.dim() == 2:
            h, c = h.unsqueeze(0), c.unsqueeze(0)
        elif h.dim() == 1:
            h, c = h.unsqueeze(0).unsqueeze(0), c.unsqueeze(0).unsqueeze(0)
        return (h, c)
