import
  std/strutils,
  cvc/[sims, replays]

const
  RecordedActions = staticRead("../out/engine-actions.csv")
  OriginalHashes = staticRead("../out/steps-before.hashes")

let hashes = OriginalHashes.splitLines()
var world = initWorld(1)
for line in RecordedActions.splitLines():
  if line.len == 0:
    continue
  let fields = line.split(',')
  var actions: Actions
  for i in 0 ..< CogCount:
    actions[i] = Action(parseInt(fields[i]))
  world.tick(actions)
  doAssert $world.stateHash == hashes[world.tick - 1]
doAssert world.tick == MaxTicks
echo "All 10,000 original simulation hashes match."
when not defined(emscripten):
  let session = load("out/engine-benchmark.replay")
  while session.world.tick < MaxTicks:
    session.advance()
  doAssert session.world.stateHash == world.stateHash
  echo "Original recorded replay still plays correctly."
