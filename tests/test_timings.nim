import cvc/[common, timings]

var pending = 0.0
for frame in 0 ..< 300:
  doAssert frameTicks(pending, 1.0 / 60, 1000) == MaxFrameSteps
  doAssert pending < 1.0 / TickRate

# Slowing down must work even without the UI explicitly clearing pending time.
var ticks = 0
for frame in 0 ..< 60:
  let steps = frameTicks(pending, 1.0 / 60, 1)
  doAssert steps <= 1
  ticks += steps
doAssert ticks == TickRate

# Arbitrary CLI speeds retain fractional time across frames.
pending = 0
ticks = 0
for frame in 0 ..< 60:
  ticks += frameTicks(pending, 1.0 / 60, 7)
doAssert ticks in 139 .. 140
doAssert pending < 1.0 / TickRate

# A stalled frame cannot leave a multi-frame catch-up backlog.
pending = 1000
doAssert frameTicks(pending, 1.0, 1000) == MaxFrameSteps
doAssert frameTicks(pending, 0.0, 1) == 0
echo "Fast-to-slow playback, fractional rates, and bounded catch-up pass."
