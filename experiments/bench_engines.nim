import
  std/[monotimes, times, strutils],
  cvc/[sims, bots, replays]

proc seconds(started: MonoTime): float64 =
  ## Returns elapsed monotonic wall time without including setup.
  (getMonoTime() - started).inNanoseconds.float64 / 1_000_000_000

proc benchmark() =
  ## Compares complete matches with shared actions and optional policy work.
  let
    source = newSession(1)
    policies = newBots()
  for tick in 0 ..< MaxTicks:
    source.advance(policies.decide(source.world))
  var csv = ""
  for frame in source.tape.actions:
    for i, action in frame.actions:
      if i > 0:
        csv.add(',')
      csv.add($ord(action))
    csv.add('\n')
  writeFile("out/engine-actions.csv", csv)
  source.save("out/engine-benchmark.replay")
  for round in 0 ..< 3:
    var world = initWorld(1)
    var started = getMonoTime()
    for frame in source.tape.actions:
      world.tick(frame.actions)
    echo "simulation,", round, ",", seconds(started), ",", world.stateHash
    doAssert world.stateHash == source.world.stateHash
    world = initWorld(1)
    started = getMonoTime()
    for tick in 0 ..< MaxTicks:
      world.tick(default(Actions))
    echo "idle,", round, ",", seconds(started), ",", world.stateHash
    let recorded = newSession(1)
    started = getMonoTime()
    for frame in source.tape.actions:
      recorded.advance(frame.actions)
    echo "recorded,", round, ",", seconds(started), ",", recorded.world.stateHash
    doAssert recorded.world.stateHash == source.world.stateHash
    let
      live = newSession(1)
      bots = newBots()
    started = getMonoTime()
    for tick in 0 ..< MaxTicks:
      live.advance(bots.decide(live.world))
    echo "live,", round, ",", seconds(started), ",", live.world.stateHash
    doAssert live.world.stateHash == source.world.stateHash

benchmark()
