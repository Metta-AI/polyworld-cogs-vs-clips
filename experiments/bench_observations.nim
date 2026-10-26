import
  std/[monotimes, times, strutils, os],
  cvc/[sims, observations]

when defined(cvcObsTrace):
  import cvc/profiles

var frames: seq[Actions]
for line in readFile("out/engine-actions.csv").splitLines:
  if line.len == 0:
    continue
  var actions: Actions
  let values = line.split(',')
  doAssert values.len == CogCount
  for slot in 0 ..< CogCount:
    actions[slot] = Action(parseInt(values[slot]))
  frames.add actions
doAssert frames.len == MaxTicks

var checksum: uint64
for round in 0 ..< 4:
  var
    world = initWorld(1)
    observer: Observer
    observations: ObservationBatch
  let started = getMonoTime()
  for index, actions in frames:
    when defined(cvcObsTrace):
      if index == 9000:
        startCapture()
    world.tick(actions)
    when defined(cvcObsReference):
      world.observeReference(observations)
    else:
      observer.observe(world, observations)
    checksum += observations[0][0][2]
    when defined(cvcObsTrace):
      if index == 9099:
        finishCapture(paramStr(1))
        quit(0)
  let elapsed = (getMonoTime() - started).inNanoseconds.float64 / 1e9
  doAssert world.stateHash == 3548051309'u64
  if round > 0:
    echo "simulation+observations,", round, ",", elapsed
# Consume the observations so optimized builds cannot discard the writes.
echo "checksum,", checksum
