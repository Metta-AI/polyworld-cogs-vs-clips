import common

const MaxFrameSteps* = 20

proc frameTicks*(pending: var float64, elapsed, rate: float64): int =
  ## Budgets client ticks without retaining excess time from an overloaded frame.
  pending = min(
    pending + max(0.0, elapsed) * rate,
    MaxFrameSteps.float64 / TickRate.float64
  )
  result = min(MaxFrameSteps, int(pending * TickRate.float64))
  pending = max(0.0, pending - result.float64 / TickRate.float64)
