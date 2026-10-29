# Safa BASIC tensor policy

`players/neural/safa.bas` implements the CNN, group normalization, feature
branches, LSTM, action head and sampling in BASIC with Polyworld tensor
operations. There is no `nn_safa` host function. `observationTensor(role, output)`
only copies the visible 134-feature view into a policy-owned float32 tensor.
Other BASIC bots can continue using direct queries without building this view.
`randomInt(bound)` uses a per-seat RNG independent of the simulation.

`tools/package_safa_tensors.py` packages the BASIC entry point, named tensor
manifest and unchanged exported weights from `out/safa/model.bin`. The package
is `out/safa/safa-tensors.zip`. Its metadata preserves the original checkpoint
fingerprint. The 134-feature contract remains reconstructed; the exact original
submission metadata was not available. Reward inputs are zero and station protocol hints are reconstructed from the
frozen rules. Other cogs use assumed role assignments. The dense view does not
reproduce the original 500-token truncation.

The network's recurrent float32 output is checked against PyTorch fixtures in
`tests/test_safa_tensors.nim`. Final sampling converts exponentiated logits to
BASIC fixed-point and uses a bounded 14-bit random draw. It need not choose the
same sampled actions as the older native wrapper. Weights are unchanged and
there is no scripted action fallback.

The hosted image enables `-d:tensorBlas` and single-threaded OpenBLAS. Portable
builds support the same tensor program with slower ordered float32 kernels.
Each seat retains independent LSTM state. Tensor operations charge VM work and
memory. The policy prints initialization and its completed inference count to
its private hosted log.

```sh
python3 tools/package_safa_tensors.py --checkpoint /path/to/model_036992.pt
nim r -d:release -d:headless -d:tensorBlas tests/test_safa_tensors.nim
nim r -d:release -d:headless -d:tensorBlas src/cvc.nim \
  --bots:out/safa/safa-tensors.zip:8 --bots:players/base.bas:24 \
  --record:out/safa/tensor-versus-base.replay
```

## Hosted verification

On 2026-10-29, `cvc-pw-safa-tensors-houck:v1` was submitted as Andre von Houck
and became an active competing champion. CoWorld 0.1.5 passed all 10 hosted
certification checks and five smoke games.

A hosted eight-neural-seat match completed successfully. Every Safa private
log recorded initialization, 10,000 tensor inference steps, and completion.
Safa's team scored 31.3569; the three baseline teams averaged 42.5096.
The running-to-completed interval was approximately 439 seconds.

Ladder round 88 then completed four games. Each included one Safa cog among
other policies and baseline fillers, and every Safa log again recorded all
10,000 inference steps. Its team scores were 0.2394, 0.2155, 59.6597 and
37.4188. This verifies execution and illustrates variable mixed-team results;
it is not a reliable win-rate estimate.

Earlier ladder attempts were blocked by a different entrant failing policy
loading. The league's existing failure rules automatically disqualified that
entrant. No policy fallback or manual scoring change was used.

The identifiers and verification evidence are in `safa-submission.json`.
[Hosted tensor match](https://softmax.com/observatory/v2/episode-requests/ereq_26641380-a2ca-4275-a19f-23f62028bf14/watch).
[Successful ladder replay](https://softmax.com/observatory/v2/episode-requests/ereq_fab94540-8a15-469f-ba16-864ac08bbb51/watch).
