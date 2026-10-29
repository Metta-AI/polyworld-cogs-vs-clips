# Safa FourScore curriculum port

The training adapter ports the active FourScore role curriculum at source
revision `ba2cbbace118369d405d3087febec62adc73dee9`. It changes no simulation
rules, map, scores, deterministic state, or BASIC bot behavior.

## Recipe

At each episode reset, independently for each eight-cog team:

- Guarantee one generalist, sample the remaining seven roles uniformly from
  generalist and idle, then shuffle the assignments.
- Keep those roles for the whole episode. Reward roles do not force equipment.
- Replace idle actions with uniformly sampled actions. Exclude idle seats from
  policy, value, and entropy losses with Safa's vendored PuffeRL mask.
- Generalists receive +1/-1 for gaining/losing miner, aligner or scrambler gear,
  +0.005 per resource unit gained, +1 per alignment or scramble, and -0.1 per
  heart lost. Idle rewards are zero. There is no team-score reward in this recipe.
- Keep rewards unclipped, as in the source learner.

The source
[FourScore mission](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogame-cogsguard/src/cogsguard/tutorials/four_score_role_switching_tutorial.py)
and
[launcher](https://github.com/Metta-AI/cvc-fourscore-rl-experiments/blob/ba2cbbace118369d405d3087febec62adc73dee9/cogame-cogsguard/train_four_score_role_switching.py)
are the references. This is an episode-level task distribution, not a timed
four-stage schedule. The older staged notes omit durations; the separate
shared-observation territory transition is disabled in the checked source.
Neither is silently substituted for the active FourScore recipe.

PPO uses learning rate 0.0001, entropy 0.03, gamma 0.99, GAE lambda 0.90,
one update epoch, clip 0.2, value coefficient 0.5, gradient norm 1.0, Adam
betas 0.95/0.999, and source replay-priority settings. CPU minibatches are
256 transitions, with 32-tick recurrent sequences and one match by default.
These small CPU batches are an explicit adaptation of the source GPU setup.

The source launcher defaults to five billion agent steps and demonstrates
CUDA training. It does not establish the elapsed training time or number of
steps that produced the supplied Safa checkpoint. At approximately 1,000
agent steps per second on this CPU test, that budget would take roughly
58 days. This is a throughput extrapolation, not a required learning duration
or a GPU runtime estimate. Counts include idle seats, as in the source learner.

The policy uses the source 64/128-channel CNN, GroupNorm, center-cell encoder,
512-unit LSTM, and five-action/value heads. Checkpoint parameter names and
shapes remain compatible with the Safa BASIC tensor packager. A training-only
135th observation channel marks episode boundaries; it never enters the CNN
and has no weights. It prevents recurrent state leaking between games.

## Observation and event boundaries

The network consumes the existing normalized 134-feature Polyworld grid.
Own and visible other-cog role tokens now reflect the actual sampled roles.
The original inference API keeps its previous default role behavior.

This is not full original-environment parity: team-ID bit features from newer
Safa source are absent, last-reward input remains zero, and existing synthetic
protocol hints remain. The fixed Polyworld map is unchanged. Role sampling is
seeded NumPy sampling rather than bit-identical Python random draws.

Gear and heart events use per-tick inventory deltas; resource rewards count
positive cargo deltas, not deposit events. Junction events use the simulation's
Captured/Disrupted feedback. The source engine has separate stat counters;
in this port a same-tick health depletion can overwrite that feedback with
Broken. That rare simultaneous interaction/depletion case is not exact event
parity. Terminal event deltas are preserved before automatic reset.

## Running

From the repository root, with the existing PufferLib Python environment:

```sh
sh tools/build_training.sh
/Users/me/p/PufferLib/puffer/bin/python tools/train_safa.py \
  --seconds 600 --output out/safa-next
```

Use a new output directory. The deadline covers training only and allows the
last update to finish. The runner saves initial weights, final model and
optimizer state, metrics, source/library hashes, event totals and match counts.
`--steps` additionally caps agent decisions, defaulting to the source's five
billion. The first reached budget stops training after the current update.
`--checkpoint PATH` starts from compatible weights with a fresh optimizer;
it is not exact resumption. The default is training from scratch.

`--device cuda` selects GPU learning on a CUDA machine with compatible Torch
and PufferLib installations. The simulation remains on CPU. This machine's
validation covers CPU only; GPU throughput and execution are not measured.

Evaluate the model path from summary.json, then evaluate initial.pt with the
same arguments for a matched comparison:

```sh
python tools/evaluate_safa_training.py PATH_TO_MODEL.pt \
  --output out/safa-next/trained-versus-base.json
```

Evaluation uses full 10,000-tick games, eight neural generalists against 24
base.bas cogs, and four held-out seeds with the controlled team rotated through
the corners. There are no idle substitutions in evaluation. Four games are a
small diagnostic, not a reliable population win-rate estimate.

## Source and validation

`training/safa_pufferl.py` is Safa's vendored learner with one local API change:
the unused teacher-action return field is removed to match PufferLib 3's native
seven-field buffer interface. Its MIT notice is in `safa_pufferl.LICENSE`.
The runner disables optional utilization monitoring when the OS hides CPU
counts. It does not change the training objective.

Validation includes seeded role assignment and per-team guarantees, correct
role observation IDs, reset renewal, LSTM memory clearing, a real masked PPO
update with no parameter changes, native reward events across terminal resets,
and the existing direct-simulation equivalence test.

## October 29 test

The from-scratch CPU run completed 600.747 seconds, 663,552 agent steps,
648 updates and two full training matches. Weights changed by L2 distance
8.61536 and recorded policy/value losses remained finite. Active seats gathered
resources but recorded no alignment or scramble events. Counts include idle
seats, which do not contribute PPO loss.

| Four held-out games against base.bas | Initial CNN/LSTM | Trained CNN/LSTM |
| --- | ---: | ---: |
| Mean score | 0.154625 | 0 |
| Outright wins | 0 of 4 | 0 of 4 |

This test demonstrates functioning training, not useful learned play. The
[receipt](safa-curriculum-test-20261029.json) contains the exact configuration,
hashes and per-game results. It records the test's nominal one-billion-step
priority-annealing horizon; the final CLI exposes `--steps` and defaults to
the source's five billion. The wall-clock limit stopped this test much earlier.

The model is in
`out/safa-curriculum-10min-20261029/179329635273/model_000648.pt`.
`out/safa-curriculum-10min-20261029/player.zip` packages those weights with
the existing BASIC tensor policy and passed an eight-seat, 20-tick native
execution check. No policy was uploaded or changed on the ladder.
