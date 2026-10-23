import cvc/[sims, replays]

proc reference(world: World, tile: int32): Owner =
  ## Reproduces the original integer influence calculation independently.
  var strengths: array[Owner, int32]
  for station in world.stations:
    if station.owner == Neutral or
      station.kind notin {Hub, Junction, Ship}:
        continue
    let
      radius = if station.kind == Hub: HubRadius else: TerritoryRadius
      distance = station.tile.distance2(tile)
    if distance < radius * radius:
      strengths[station.owner] += radius * 1024 -
        root(int64(distance) * 1024 * 1024)
  var best = 0'i32
  for team in Teams:
    if strengths[team] > best:
      best = strengths[team]
      result = team
    elif strengths[team] == best:
      result = Neutral

for seed in [1'i32, 42, -1]:
  var world = initWorld(seed)
  for i in 0 ..< world.stations.len:
    world.stations[i].owner = Owner(i mod 5)
  for tile in 0'i32 ..< TileCount:
    doAssert world.territory(tile) == world.reference(tile)
  for base in countup(0, TileCount - 1, CogCount):
    for i in 0 ..< CogCount:
      world.cogs[i].tile = int32((base + i) mod TileCount)
      world.cogs[i].role = Scout
      world.cogs[i].hp = 100
      world.cogs[i].energy = 0
    var expected: array[CogCount, Owner]
    for i, cog in world.cogs:
      expected[i] = world.reference(cog.tile)
    world.tick(default(Actions))
    for i, cog in world.cogs:
      let hp =
        if expected[i] == cog.team: 199
        elif expected[i] == Neutral: 99
        else: 98
      doAssert cog.hp == hp
  for station in world.stations.mitems:
    station.owner = Neutral
  doAssert world.territory(0) == Neutral

var ties: World
ties.stations = @[
  Station(kind: Hub, tile: 0, owner: Red),
  Station(kind: Hub, tile: 0, owner: Blue)
]
for tile in 0'i32 ..< TileCount:
  doAssert ties.territory(tile) == Neutral

echo "Territory lookup and batched effects match the original calculation."

let session = newSession(1)
session.advance(default(Actions))
session.tape.header.setup.contentHash = PreviousContentHash
let playback = loadBytes(session.replayBytes())
playback.advance()
doAssert playback.world.stateHash == session.world.stateHash
session.tape.header.setup.contentHash = 0
var rejected = false
try:
  discard loadBytes(session.replayBytes())
except CvcError:
  rejected = true
doAssert rejected
echo "Equivalent old replays load; unknown rules remain rejected."
