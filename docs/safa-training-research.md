# Safa training research

Investigated October 29, 2026. The source and reports below exist. None of the
material found establishes the exact training history of `model_036992.pt`.

## What the original source actually does

Safa already used PufferLib PPO. The
[FourScore launcher](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogame-cogsguard/train_four_score_role_switching.py)
reuses the role trainer and its modified PuffeRL idle-agent loss mask. Its
settings include learning rate 0.0001, entropy 0.03, gamma 0.99, GAE lambda
0.90, one update epoch, gradient norm 1.0, and Adam betas 0.95/0.999.
These are source defaults, not verified settings for the supplied checkpoint.

The
[FourScore mission](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogame-cogsguard/src/cogsguard/tutorials/four_score_role_switching_tutorial.py)
uses 32 agents in four teams. Role assignment happens independently per team,
with a mandatory set and random remaining assignments at episode reset.
At this revision the active pool is generalist and idle, with one guaranteed
generalist per team. Other specialist and combination roles exist in the
code but are commented out of the active sampling pool.

Rewards provide direct credit for prerequisite behaviors. The generalist gets
1.0 for acquiring miner/aligner/scrambler gear, -1.0 for losing it, 0.005 per
resource gained, 1.0 for aligning or scrambling a junction, and -0.1 per
heart lost. These are per-agent stat deltas, not just the final team score.
The shared role handler enables Python reward replacement, excludes idle
agents from gradients, and makes idle agents act randomly. Comments in some
places still describe idle as noop; the live flag is random.

Our existing Safa inference port uses a spatial CNN, a center-cell encoder,
and a 512-unit LSTM. That is substantially different from the tiny flat-token
MLP used in the local CPU smoke trainer. Learning a spatial, stateful policy
with useful individual credit is a plausible explanation for useful behavior;
it is not an ablation proving why this particular checkpoint is strong.

## Is there a curriculum to copy?

Yes, but there are several different experiments, not one verified recipe.

1. The brief original
   [training strategy notes](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogames_old/train_strategy.md)
   list four sub-policy phases: learning rate/entropy 0.0003/0.03,
   0.0001/0.01, 0.0001/0.001, then the same values with mandatory shapers
   removed. Miner element-loss penalties are disabled throughout. Phase
   durations and checkpoint lineage are absent, so the schedule cannot be
   faithfully reproduced just from this note.
2. Role-conditioned training changes the tasks agents practice by sampling
   roles and shaping their rewards. This is directly reusable in principle,
   but requires matching the observation contract and role-specific event
   counters, not merely changing PPO hyperparameters.
3. A separate
   [shared-observation experiment](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogame-cogsguard/src/cogsguard/tutorials/shared_obs_territory_tutorial.py)
   contains a linear generalist-to-territory reward transition over one billion
   steps. Gear and survival terms are exempt from decay. However, the checked
   revision sets `FIXED_REWARD_BLEND=True`, generalist coefficient 1.0 and
   territory coefficient 0.0: that curriculum is disabled. The source comments
   say increasing the shared territory term destabilized earlier runs.

The FourScore source currently enables team-ID observation bits, whereas our
candidate 134-feature checkpoint contract excludes them. This is another
reason not to claim that the current source defaults produced these weights.

## Reports found

There are detailed later reproduction reports in Metta, rather than a complete
first-person success report tied to Safa's supplied weights:

- [B300 pilot](https://github.com/Metta-AI/metta/blob/7ef26cc0a123a775c600a9a2f9971f822f1f68c1/docs/specs/0095-safa-b300/README.md):
  improved shaped reward did not establish territory learning. It also links
  frozen configurations and a reconstructed curriculum.
- [Evidence digest](https://github.com/Metta-AI/metta/blob/7ef26cc0a123a775c600a9a2f9971f822f1f68c1/docs/specs/0095-safa-b300/evidence-digest.md):
  mixed-horizon expert continuations learned some territory control, but did
  not establish full-game parity. More imitation accuracy and shaped reward
  were unreliable measures of game strength.
- [Workspace closeout](https://github.com/Metta-AI/metta/blob/7ef26cc0a123a775c600a9a2f9971f822f1f68c1/docs/specs/0095-safa-b300/workspace-closeout-20261001.md):
  preserves additional negative and mixed results plus artifact locators.

These studies include eight-agent Cogs-versus-Clips experiments. Their results
must not be presented as FourScore results or evaluations of `model_036992.pt`.

## Recommended Polyworld experiment

The [active FourScore curriculum port](safa-curriculum.md) now implements the
individual reward events, per-team role assignment, idle loss masking, and
spatial recurrent policy in the training adapter. Frozen game rules are
unchanged. Its documented observation and event differences still prevent a
claim of exact original-environment parity. Keep the basic
gather/deposit/capture CPU trainer as an integration baseline.

Evaluate on full 10,000-tick games against base.bas, rotating teams and using
held-out seeds. Measure actual score, territory, deposits, and captures.
Only then compare a staged schedule or territory blend against the fixed
reward control. Do not infer improvement from finite losses, changed weights,
or increasing shaped reward alone.
