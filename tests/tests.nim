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
  doAssert Width == 120 and Height == 120 and CogCount == 32
  var counts: array[Owner, int]
  for cog in world.cogs:
    inc counts[cog.team]
  for team in Teams:
    doAssert counts[team] == TeamSize
    doAssert world.banks[team] == [24'i32, 24, 24, 24]
    doAssert world.hearts[team] == 5
    doAssert world.stations[ord(team) - 1].tile == team.home
  for station in world.stations:
    doAssert station.kind != Ship
  var gear = -1
  for i, station in world.stations:
    if station.kind == Gear and station.owner == Red and station.role == Miner:
      gear = i
  doAssert gear >= 0
  let otherSeed = initWorld(43)
  doAssert world.tiles == otherSeed.tiles
  doAssert world.stateHash == initWorld(42).stateHash
  doAssert world.stateHash != initWorld(43).stateHash
  world.useStation(0, gear)
  doAssert world.cogs[0].role == Miner
  doAssert world.banks[Red] == [23'i32, 23, 21, 23]
  world.useStation(0, gear)
  doAssert world.banks[Red] == [23'i32, 23, 21, 23]
  var extractor = -1
  for i, station in world.stations:
    if station.kind == Extractor:
      extractor = i
      break
  let element = world.stations[extractor].element
  world.useStation(0, extractor)
  doAssert world.cogs[0].cargo[element] == 10
  doAssert world.stations[extractor].stock == 90
  let bankBeforeDeposit = world.banks[Red][element]
  world.useStation(0, 0)
  doAssert world.cogs[0].carried == 0
  doAssert world.banks[Red][element] == bankBeforeDeposit + 10
  world.useStation(0, 0)
  doAssert world.cogs[0].hearts == 1 and world.hearts[Red] == 4
  world.hearts[Red] = 0
  let before = world.banks[Red]
  world.useStation(0, 0)
  for element in Element:
    doAssert world.banks[Red][element] == before[element] - HeartCost
  world.cogs[0].role = Aligner
  for i, station in world.stations:
    if station.kind == Junction and world.linked(station.tile, Red):
      world.useStation(0, i)
      doAssert world.stations[i].owner == Red
      world.stations[i].owner = Blue
      world.cogs[0].role = Scrambler
      world.useStation(0, i)
      doAssert world.stations[i].owner == Neutral
      break
  world.cogs[0].tile = tileAt(30, 31)
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
  echo "Replay score: ", live.world.scores

proc testTerritory() =
  ## Checks ties, disconnection, independent team scores, and match end.
  var world = initWorld(1)
  world.stations.setLen(0)
  world.stations.add Station(
    kind: Junction, tile: tileAt(30, 40), owner: Red
  )
  world.stations.add Station(
    kind: Junction, tile: tileAt(40, 40), owner: Blue
  )
  doAssert world.territory(tileAt(35, 40)) == Neutral
  doAssert world.territory(tileAt(31, 40)) == Red
  world.reconnect()
  doAssert world.stations[0].owner == Neutral
  doAssert world.stations[1].owner == Neutral
  world = initWorld(2)
  world.stations.setLen(0)
  for i, team in Teams:
    for j in 0 .. i:
      world.stations.add Station(kind: Junction,
        tile: tileAt(int32(10 + i * 25), int32(10 + j)), owner: team)
  world.tick(default(Actions))
  for i, team in Teams:
    doAssert world.scores[team] == int64(i + 1)
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
      world.stations[i].owner = Red
  world.reconnect()
  let
    before = world.stateHash
    ground = world.terrain()
    links = world.pipes()
  doAssert world.stateHash == before
  doAssert links.len > 0
  doAssert links.len <= MaxStations * 50
  doAssert world.pipes() == links
  for tile in 0 ..< TileCount:
    if world.tiles[tile].wall:
      doAssert ground.edges[tile] == 49
  doAssert world.terrain() == ground
  doAssert ground.splats.len <= TileCount div 25
  for link in links:
    doAssert link.tile in 0 ..< TileCount
    doAssert not world.tiles[link.tile].wall

block:
  var world = initWorld(1)
  world.tick = 5
  world.cogs[0].feedback = Blocked
  let start = world.cogs[0].tile
  for i, action in [North, East, South, West]:
    world.cogs[i + 1].tile = start.neighbor(action)
  let policies = newBots()
  doAssert policies.decide(world)[0] == Rest

echo "Surrounded baseline bots wait instead of making blind blocked moves."

block:
  var world = initWorld(1)
  world.cogs[0].cargo[Carbon] = 4
  let banks = world.banks
  world.useStation(0, 1)
  doAssert world.banks == banks
  doAssert world.cogs[0].cargo[Carbon] == 4
  world.useStation(0, 0)
  doAssert world.banks[Red][Carbon] == banks[Red][Carbon] + 4
  for team in [Blue, Green, Gold]:
    doAssert world.banks[team] == banks[team]
  for team in Teams:
    let slot = (ord(team) - 1) * TeamSize
    world.cogs[slot].tile = team.home.neighbor(North)
    world.cogs[slot].hp = 20
  world.tick(default(Actions))
  for team in Teams:
    doAssert world.cogs[(ord(team) - 1) * TeamSize].hp == 100
  let policies = newBots("act(self(8))")
  let actions = policies.decide(world)
  for i, action in actions:
    doAssert ord(action) == ord(world.cogs[i].team)

echo "Four teams isolate banks, heal their own Cogs, and expose team identity."
