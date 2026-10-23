import
  std/[monotimes, times, os],
  cvc/[sims, replays, scrubs, pipes, bots]

proc fixture(): Session =
  ## Loads a requested replay or generates a self-contained baseline match.
  if paramCount() > 0:
    return load(paramStr(1))
  result = newSession(1)
  let policies = newBots()
  for tick in 0 ..< 10000:
    result.advance(policies.decide(result.world))
  result = fromReplay(result.tape)

let
  session = fixture()
  started = getMonoTime()
  cache = buildScrubs(session.tape)
echo "Indexed ", cache.duration, " ticks in ",
  (getMonoTime() - started).inMilliseconds, " ms."
doAssert cache.points.len <= ScrubSegments + 1
doAssert cache.points[0].world.tick == 0
doAssert cache.points[^1].world.tick == cache.duration
for i, point in cache.points:
  let tick = point.world.tick
  doAssert point.world.stateHash ==
    (if tick == 0: session.tape.header.setup.mapHash
    else: session.tape.hashes[tick - 1])
  doAssert cache.pointAt(tick) == i
  doAssert cache.pointAt(tick, true) == i
  restorePipes(point.pipes)
  let before = pipeSnapshot()
  var changed = point.world
  changed.stations[0].owner = Neutral
  updatePipegridState(changed)
  restorePipes(point.pipes)
  doAssert pipeSnapshot() == before
  doAssert point.world.stateHash ==
    (if tick == 0: session.tape.header.setup.mapHash
    else: session.tape.hashes[tick - 1])

let previewStarted = getMonoTime()
for drag in 0 ..< 1000:
  let point = cache.points[cache.pointAt(int32(drag * 37 mod 10001), true)]
  session.world = point.world
  restorePipes(point.pipes)
echo "1,000 cached preview restores in ",
  (getMonoTime() - previewStarted).inMilliseconds, " ms."

for target in [1'i32, 499, 500, 501, 1379, 9999, 10000]:
  let point = cache.points[cache.pointAt(target)]
  session.world = point.world
  restorePipes(point.pipes)
  var explored = point.explored
  while session.world.tick < target:
    session.advance()
    updatePipegridState(session.world)
    explored.observeExploration(session.world)
  doAssert session.world.stateHash == session.tape.hashes[target - 1]
  let actualPipes = pipeSnapshot()
  session.world = point.world
  restorePipes(point.pipes)
  while session.world.tick < target:
    session.advance()
    updatePipegridState(session.world)
  doAssert pipeSnapshot() == actualPipes

for length in [0, 1, 7, 19, 20, 21, 99]:
  let short = newSession(1)
  for tick in 0 ..< length:
    short.advance()
  let visible = pipeSnapshot()
  var indexed = beginScrubs(short.tape)
  doAssert pipeSnapshot() == visible
  doAssert indexed.available(0)
  doAssert indexed.requiredTick(int32(length), true) == length
  if length > 0:
    doAssert not indexed.available(int32(length), true)
  while not indexed.complete():
    indexed.extendScrubs(0)
    doAssert pipeSnapshot() == visible
  doAssert indexed.points.len == min(length + 1, ScrubSegments + 1)
  doAssert indexed.points[^1].world.tick == length
  doAssert indexed.pointAt(-1) == 0
  doAssert indexed.pointAt(10000, true) == indexed.points.high
echo "Scrub endpoints, short replays, exact seeks, and snapshot isolation pass."
