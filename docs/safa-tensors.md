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
