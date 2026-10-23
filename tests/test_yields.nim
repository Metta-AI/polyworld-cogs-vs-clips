import cvc/[sims, yields, routes, bots]

var world = initWorld(1)
let
  start = tileAt(50, 50)
  destination = start.neighbor(East)
world.tiles[destination].station = -1
world.cogs[0].tile = start
world.cogs[1].tile = start
var waits, different = 0
for tick in 0 ..< 1000:
  world.tick = int32(tick)
  var first, second, repeat: YieldMemory
  let
    a = first.yieldMove(world, 0, East, true)
    b = second.yieldMove(world, 1, East, true)
  doAssert repeat.yieldMove(world, 0, East, true) == a
  if a == Rest:
    inc waits
  if a != b:
    inc different
  var free: YieldMemory
  doAssert free.yieldMove(world, 0, East, false) == East
  world.tiles[destination].station = 0
  doAssert first.yieldMove(world, 0, East, true) == East
  world.tiles[destination].station = -1
doAssert waits in 430 .. 570
doAssert different in 430 .. 570
echo "Crowded waits: ", waits, "/1000; different seat decisions: ", different

var consecutive, alternating = 0
for tick in 0 ..< 1000:
  world.tick = int32(tick)
  var memory: YieldMemory
  doAssert memory.yieldMove(world, 0, East, false) == East
  if memory.yieldMove(world, 0, East, false) == Rest:
    inc consecutive
  memory = default(YieldMemory)
  discard memory.yieldMove(world, 0, East, false)
  discard memory.yieldMove(world, 0, Rest, false)
  if memory.yieldMove(world, 0, East, false) == Rest:
    inc alternating
doAssert consecutive == waits and alternating == waits

let router = newRoutes()
discard router.findRoute(start, tileAt(60, 50), [destination])
doAssert router.crowded
discard router.findRoute(start, tileAt(60, 50), [])
doAssert not router.crowded

let
  before = world.stateHash
  custom = newBots("act(2)")
let actions = custom.decide(world)
for action in actions:
  doAssert action == East
doAssert world.stateHash == before
echo "Repeated destinations yield; station use and explicit BASIC actions do not."
