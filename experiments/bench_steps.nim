import
  std/[monotimes, times],
  cvc/[sims, replays]

let tape = load("out/engine-benchmark.replay").tape
var expected: uint64
for round in 0 ..< 4:
  var world = initWorld(tape.config.seed)
  let started = getMonoTime()
  for frame in tape.actions:
    world.tick(frame.actions)
  let elapsed = (getMonoTime() - started).inNanoseconds.float64 / 1e9
  if round == 0:
    expected = world.stateHash
  else:
    doAssert world.stateHash == expected
    echo "simulation,", round, ",", elapsed, ",", expected
