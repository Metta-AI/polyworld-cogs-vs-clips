import
  cvc/[sims, replays, bots, terrains]

proc reject(bytes: string) =
  ## Requires malformed input to fail through the game error boundary.
  var rejected = false
  try:
    discard loadBytes(bytes)
  except CvcError:
    rejected = true
  doAssert rejected

proc testRules() =
  ## Exercises independent rule transitions with directly arranged fixtures.
  var world = initWorld(42)
  doAssert world.stations.len <= MaxStations
  var walls = 0
  for tile in world.tiles:
    if tile.wall:
      inc walls
  doAssert walls == 1397
  doAssert world.stations[0].kind == Hub
  doAssert world.stations[0].tile == tileAt(43, 43)
  doAssert world.cogs[0].tile == tileAt(43, 40)
  let otherSeed = initWorld(43)
  doAssert world.tiles == otherSeed.tiles
  doAssert world.stateHash == initWorld(42).stateHash
  doAssert world.stateHash != initWorld(43).stateHash
  world.useStation(0, 1)
  doAssert world.cogs[0].role == Miner
  doAssert world.bank == [23'i32, 23, 21, 23]
  world.useStation(0, 1)
  doAssert world.bank == [23'i32, 23, 21, 23]
  var extractor = -1
  for i, station in world.stations:
    if station.kind == Extractor:
      extractor = i
      break
  let element = world.stations[extractor].element
  world.useStation(0, extractor)
  doAssert world.cogs[0].cargo[element] == 10
  doAssert world.stations[extractor].stock == 190
  let bankBeforeDeposit = world.bank[element]
  world.useStation(0, 0)
  doAssert world.cogs[0].carried == 0
  doAssert world.bank[element] == bankBeforeDeposit + 10
  world.useStation(0, 0)
  doAssert world.cogs[0].hearts == 1 and world.hearts == 4
  world.hearts = 0
  let before = world.bank
  world.useStation(0, 0)
  for element in Element:
    doAssert world.bank[element] == before[element] - HeartCost
  world.cogs[0].role = Aligner
  for i, station in world.stations:
    if station.kind == Junction and world.linked(station.tile, Cogs):
      world.useStation(0, i)
      doAssert world.stations[i].owner == Cogs
      world.stations[i].owner = Clips
      world.cogs[0].role = Scrambler
      world.useStation(0, i)
      doAssert world.stations[i].owner == Neutral
      break
  world.cogs[0].tile = tileAt(44, 45)
  for i in 0 ..< 5:
    world.tick(default(Actions))
  doAssert world.cogs[0].hp == world.cogs[0].role.maxHp
  doAssert world.cogs[0].energy == world.cogs[0].role.maxEnergy
  world.cogs[0].tile = tileAt(1, 1)
  world.cogs[0].hp = 1
  world.cogs[0].hearts = 4
  world.tick(default(Actions))
  doAssert world.cogs[0].hp == 0
  doAssert world.cogs[0].role == Ungeared
  doAssert world.cogs[0].hearts == 0
  let oldTile = world.cogs[1].tile
  world.cogs[0].tile = oldTile.neighbor(West)
  world.cogs[0].energy = 20
  var actions: Actions
  actions[0] = East
  world.tick(actions)
  doAssert world.cogs[0].tile != oldTile

proc testReplay() =
  ## Verifies replay reconstruction and seeking across cached checkpoints.
  let
    live = newSession(13)
    policies = newBots()
  for i in 0 ..< 1100:
    live.advance(policies.decide(live.world))
  for slot in 0 ..< CogCount:
    doAssert policies.policyError(slot).len == 0
  let playback = loadBytes(live.replayBytes())
  while playback.world.tick < live.world.tick:
    playback.advance()
  doAssert playback.world.stateHash == live.world.stateHash
  for destination in [0'i32, 999, 500, 1100, 24, 1100]:
    playback.seek(destination)
    if destination > 0:
      doAssert playback.world.stateHash == live.tape.hashes[destination - 1]
  var corrupt = live.tape
  corrupt.hashes[10] = corrupt.hashes[10] xor 1
  let broken = fromReplay(corrupt)
  var failed = false
  try:
    broken.seek(11)
  except CvcError:
    failed = true
  doAssert failed and broken.error == "replay diverged at tick 11"
  reject("")
  reject("not a replay")
  reject(live.replayBytes()[0 .. 80])
  var invalid = live.tape
  invalid.header.gameVersion = GameVersion + 1
  var rejected = false
  try:
    discard fromReplay(invalid)
  except CvcError:
    rejected = true
  doAssert rejected
  invalid = live.tape
  invalid.actions[0].tick = 3
  rejected = false
  try:
    discard fromReplay(invalid)
  except CvcError:
    rejected = true
  doAssert rejected
  echo "Replay score: ", live.world.score

proc testTerritory() =
  ## Checks ties, disconnection, independent Clips lanes, and score totals.
  var world = initWorld(1)
  world.stations.setLen(0)
  world.stations.add Station(
    kind: Junction, tile: tileAt(30, 40), owner: Cogs
  )
  world.stations.add Station(
    kind: Junction, tile: tileAt(40, 40), owner: Clips
  )
  doAssert world.territory(tileAt(35, 40)) == Neutral
  doAssert world.territory(tileAt(31, 40)) == Cogs
  world.reconnect()
  doAssert world.stations[0].owner == Neutral
  doAssert world.stations[1].owner == Neutral
  world = initWorld(2)
  world.tick = ClipsStart
  world.spread()
  var count = 0
  for station in world.stations:
    if station.kind == Junction and station.owner == Clips:
      inc count
      doAssert station.lane in 1 .. 4
  doAssert count == 4
  let score = world.clipsScore
  world.tick = ClipsStart + 1
  world.tick(default(Actions))
  doAssert world.clipsScore == score + 4
  world.tick = MaxTicks
  let hash = world.stateHash
  world.tick(default(Actions))
  doAssert world.stateHash == hash

proc testVision() =
  ## Confirms local vision boundaries and invalid-action policy isolation.
  var world = initWorld(1)
  doAssert world.visible(0, world.cogs[0].tile)
  doAssert not world.visible(0, tileAt(1, 1))
  let policies = newBots("act(99)")
  doAssert policies.decide(world) == default(Actions)
  doAssert policies.policyError(0).len == 0

echo "Testing fixed rules"
testRules()
testTerritory()
testVision()
echo "Testing BASIC policies and action replay"
testReplay()
echo "All tests passed"

echo "Testing presentation isolation and terrain edges"
block:
  var world = initWorld(42)
  for i in 0 ..< world.stations.len:
    if world.stations[i].kind == Junction:
      world.stations[i].owner = Cogs
  world.reconnect()
  let
    before = world.stateHash
    ground = world.terrain()
    links = world.pipes()
  doAssert world.stateHash == before
  doAssert links.len > 0
  doAssert links.len <= MaxStations * 50
  doAssert world.pipes() == links
  doAssert ground.edges[tileAt(0, 0)] == 49
  doAssert ground.edges[tileAt(44, 44)] == 50
  doAssert ground.edges[tileAt(1, 1)] != 50
  doAssert world.terrain() == ground
  doAssert ground.splats.len <= TileCount div 25
  for link in links:
    doAssert link.tile in 0 ..< TileCount
    doAssert not world.tiles[link.tile].wall
  world.tiles[tileAt(45, 44)].wall = true
  let broken = world.terrain()
  doAssert broken.edges[tileAt(45, 44)] == 49
  doAssert broken.edges[tileAt(44, 44)] != ground.edges[tileAt(44, 44)]
