import
  std/[strutils, os],
  cvc/sims

when defined(cvcSimTrace):
  import cvc/profiles
else:
  import std/[monotimes, times]

var frames: seq[Actions]
for line in readFile("out/engine-actions.csv").splitLines:
  if line.len == 0:
    continue
  let fields = line.split(',')
  doAssert fields.len == CogCount
  var actions: Actions
  for i in 0 ..< CogCount:
    actions[i] = Action(parseInt(fields[i]))
  frames.add(actions)
doAssert frames.len == MaxTicks

when defined(cvcSimTrace):
  var world = initWorld(1)
  for i, actions in frames:
    if i == 9000:
      startCapture()
    world.tick(actions)
    if i == 9099:
      finishCapture(paramStr(1))
      break
else:
  for round in 0 ..< 6:
    var world = initWorld(1)
    let started = getMonoTime()
    for actions in frames:
      world.tick(actions)
    let elapsed = (getMonoTime() - started).inNanoseconds.float64 / 1e9
    doAssert world.stateHash == 3548051309'u64
    if round > 0:
      echo "simulation,", round, ",", elapsed, ",", world.stateHash
  if paramCount() > 0:
    var
      world = initWorld(1)
      hashes: string
    for actions in frames:
      world.tick(actions)
      hashes.add($world.stateHash & "\n")
    writeFile(paramStr(1), hashes)
