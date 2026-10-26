import cvc/[sims, plans]

var world: World
for tile in world.tiles.mitems:
  tile.station = -1
let
  start = tileAt(5, 5)
  target = tileAt(7, 5)
world.tiles[tileAt(6, 5)].wall = true
let route = world.path(start, target)
doAssert route.len == 5
doAssert route[0] == start and route[^1] == target
for i in 1 ..< route.len:
  doAssert route[i].distance2(route[i - 1]) == 1
  doAssert not world.tiles[route[i]].wall
var plan: Plan
plan.order(target, false)
for i in 0 ..< 100:
  plan.order(target, true)
doAssert plan.targets.len == MaxWaypoints
plan.order(target, false)
world.cogs[0].tile = start
doAssert plan.action(world, 0) != East
world.cogs[0].tile = target
plan.arrive(world, 0)
doAssert plan.targets.len == 0
world.tiles[target].wall = true
doAssert world.path(start, target).len == 0
echo "Manual routes avoid walls; queues are bounded and complete."
