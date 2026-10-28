import cvc/[common, directors, sims]

proc addStation(world: var World, kind: StationKind, x, y: int32,
    owner: Owner) =
  ## Adds one station to a small deterministic camera fixture.
  let tile = tileAt(x, y)
  world.tiles[tile].station = world.stations.len.int16
  world.stations.add Station(kind: kind, tile: tile, owner: owner)

proc scene(): World =
  ## Builds a rooted chain and independent capture sites on open terrain.
  for tile in result.tiles.mitems:
    tile.station = -1
  result.addStation(Hub, 10, 60, Red)
  for x in [35'i32, 60, 85]:
    result.addStation(Junction, x, 60, Red)
  result.addStation(Hub, 60, 15, Blue)
  result.addStation(Junction, 61, 15, Neutral)
  result.addStation(Junction, 85, 15, Neutral)
  result.cogs[0] = Cog(team: Blue, tile: tileAt(34, 60),
    role: Scrambler, hearts: 3, hp: 300, energy: 20)
  result.cogs[1] = Cog(team: Blue, tile: tileAt(84, 15),
    role: Aligner, hearts: 3, hp: 100, energy: 20)

var
  before = scene()
  small = before
  large = before
  cut = before
small.stations[5].owner = Blue
large.stations[6].owner = Blue
cut.stations[1].owner = Neutral
cut.reconnect()
let
  smallArea = changedArea(before, small)
  largeArea = changedArea(before, large)
  cutArea = changedArea(before, cut)
doAssert smallArea < largeArea
doAssert largeArea > 100
doAssert cutArea > largeArea
doAssert cut.stations[2].owner == Neutral
doAssert cut.stations[3].owner == Neutral
var
  director = Director(enabled: true, target: -1)
  actions: Actions
  world = before
director.observe(world)
actions[0] = East
actions[1] = East
world.tick(actions)
let expectedHash = world.stateHash()
director.observe(world)
doAssert world.stateHash() == expectedHash
doAssert director.areas[0] == cutArea
doAssert director.areas[1] == largeArea
doAssert director.choose(0)
doAssert director.target == 0, "The chain cut beats a single capture."
let areas = director.areas
director.observe(world)
doAssert director.areas == areas, "Same-tick reads do not rescore."
doAssert not director.choose(1)
world.cogs[0].feedback = Idle
world.cogs[1].feedback = Idle
world.cogs[2].feedback = Gathered
for tick in 2 .. 180:
  world.tick = tick.int32
  director.observe(world)
discard director.choose(4)
discard director.choose(2)
doAssert director.target == 2, "Mining wins once the territory event fades."
director.observe(before)
doAssert director.areas == default(typeof(director.areas))
director.enabled = false
doAssert not director.choose(30)
director.reset()
doAssert not director.enabled and director.target == -1
var minorDirector = Director(enabled: true, target: -1)
minorDirector.observe(before)
small.tick = 1
small.cogs[1].tile = tileAt(60, 15)
small.cogs[1].direction = East
small.cogs[1].feedback = Captured
small.cogs[2].feedback = Gathered
minorDirector.observe(small)
doAssert minorDirector.choose(0)
doAssert minorDirector.target == 2, "A tiny capture should not beat mining."
echo "Territory areas: small=", smallArea, " capture=", largeArea,
  " chain cut=", cutArea
echo "Director area attribution, priorities, dwell and replay reset passed."
