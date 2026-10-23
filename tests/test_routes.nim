import
  std/random,
  cvc/[common, routes]

proc distance(
  walk: array[TileCount, bool],
  start, target: int32
): int32 =
  ## Computes an independent BFS shortest distance for the test oracle.
  var
    queue: array[TileCount, int32]
    depths: array[TileCount, int32]
    seen: array[TileCount, bool]
    head = 0
    tail = 1
  queue[0] = start
  seen[start] = true
  while head < tail:
    let tile = queue[head]
    inc head
    if tile == target:
      return depths[tile]
    for action in [North, East, South, West]:
      let next = tile.neighbor(action)
      if next < 0 or seen[next] or not walk[next]:
        continue
      seen[next] = true
      depths[next] = depths[tile] + 1
      queue[tail] = next
      inc tail
  -1

var
  rng = initRand(7491)
  queries = 0
for map in 0 ..< 120:
  let router = newRoutes()
  var walk: array[TileCount, bool]
  let size = if map < 100: 12 else: Width
  for tile in 0'i32 ..< TileCount:
    walk[tile] = tile.x < size and tile.y < size and rng.rand(99) >= 25
    router.remember(tile, walk[tile])
  for query in 0 ..< 100:
    let
      start = tileAt(rng.rand(size - 1).int32, rng.rand(size - 1).int32)
      target = tileAt(rng.rand(size - 1).int32, rng.rand(size - 1).int32)
      changed = tileAt(rng.rand(size - 1).int32, rng.rand(size - 1).int32)
    walk[changed] = not walk[changed]
    router.remember(changed, walk[changed])
    var occupied: seq[int32]
    for i in 0 ..< 4:
      occupied.add(tileAt(
        rng.rand(size - 1).int32,
        rng.rand(size - 1).int32
      ))
    var effective = walk
    effective[target] = true
    effective[start] = true
    let
      actual = router.findRoute(start, target, [])
      expected = effective.distance(start, target)
    doAssert actual.distance == expected,
      "Map " & $map & " query " & $query & " start " & $start &
      " target " & $target & ": " & $actual.distance & " != " & $expected
    if expected > 0:
      let next = start.neighbor(actual.action)
      doAssert next >= 0 and effective[next]
      doAssert effective.distance(next, target) == expected - 1
    let columns = router.rebuiltColumns
    let avoided = router.findRoute(start, target, occupied)
    doAssert router.rebuiltColumns == columns
    doAssert router.detourExpansions <= DetourTiles
    if avoided.action != Rest:
      let next = start.neighbor(avoided.action)
      doAssert next >= 0 and effective[next] and next notin occupied
    inc queries
echo queries, " terrain JPS+/BFS queries and bounded cog avoidance checks pass."

for mask in 0 ..< 512:
  let router = newRoutes()
  var walk: array[TileCount, bool]
  for tile in 0'i32 ..< TileCount:
    if tile.x < 3 and tile.y < 3:
      let bit = tile.y * 3 + tile.x
      walk[tile] = (mask and (1 shl bit)) != 0
    router.remember(tile, walk[tile])
  for startIndex in 0 ..< 9:
    for targetIndex in 0 ..< 9:
      let
        start = tileAt((startIndex mod 3).int32, (startIndex div 3).int32)
        target = tileAt((targetIndex mod 3).int32, (targetIndex div 3).int32)
      var effective = walk
      effective[start] = true
      effective[target] = true
      doAssert router.findRoute(start, target, []).distance ==
        effective.distance(start, target)
echo "41,472 exhaustive small-grid JPS+/BFS distances match."

block:
  let
    router = newRoutes()
    start = tileAt(20, 20)
    goal = tileAt(30, 20)
    blocker = start.neighbor(East)
  let direct = router.findRoute(start, goal, [])
  doAssert direct.action == East
  let columns = router.rebuiltColumns
  let avoided = router.findRoute(start, goal, [blocker])
  doAssert avoided.action in {North, South}
  doAssert router.detourExpansions > 0
  doAssert router.rebuiltColumns == columns
  doAssert router.findRoute(start, goal, []).action == East
  doAssert router.detourExpansions == 0
  for x in 20'i32 ..< 28:
    let position = tileAt(x, 20)
    discard router.findRoute(position, goal, [position.neighbor(East)])
    doAssert router.rebuiltColumns == columns
  router.remember(tileAt(21, 20), false)
  discard router.findRoute(start, goal, [])
  doAssert router.rebuiltColumns > columns

block:
  let router = newRoutes()
  for tile in 0'i32 ..< TileCount:
    router.remember(tile, tile.y == 20)
  let
    start = tileAt(20, 20)
    goal = tileAt(30, 20)
  doAssert router.findRoute(start, goal, []).action == East
  let columns = router.rebuiltColumns
  doAssert router.findRoute(start, goal, [tileAt(21, 20)]).action == Rest
  doAssert router.rebuiltColumns == columns
  doAssert router.detourExpansions <= DetourTiles
  doAssert router.findRoute(start, goal, []).action == East
  doAssert router.detourExpansions == 0

block:
  let router = newRoutes()
  let
    start = tileAt(20, 20)
    goal = tileAt(30, 20)
  let direct = router.findRoute(start, goal, [])
  let columns = router.rebuiltColumns
  let laterBlocker = router.findRoute(start, goal, [tileAt(25, 20)])
  doAssert laterBlocker == direct
  doAssert router.detourExpansions == 0
  doAssert router.rebuiltColumns == columns
  let nearGoal = tileAt(21, 20)
  doAssert router.findRoute(start, nearGoal, [nearGoal]).action == Rest
  doAssert router.findRoute(start, nearGoal, []).action == East
echo "Moving cogs preserve jump tables; detours, waiting, and recovery pass."

block:
  let
    router = newRoutes()
    goal = tileAt(30, 20)
    blocker = tileAt(21, 20)
  var position = tileAt(20, 20)
  discard router.findRoute(position, goal, [])
  let columns = router.rebuiltColumns
  for tick in 0 ..< 20:
    if position == goal:
      break
    let move = router.findRoute(position, goal, [blocker])
    doAssert move.action != Rest
    position = position.neighbor(move.action)
    doAssert position != blocker
    doAssert router.rebuiltColumns == columns
  doAssert position == goal
echo "Local avoidance rejoins the terrain route and reaches the goal."

block:
  let
    router = newRoutes()
    start = tileAt(20, 20)
    goal = tileAt(30, 20)
    blocker = tileAt(21, 20)
  router.remember(tileAt(20, 19), false)
  router.remember(tileAt(20, 21), false)
  discard router.findRoute(start, goal, [])
  let columns = router.rebuiltColumns
  var position = start
  for tick in 0 ..< 24:
    if position == goal:
      break
    let move = router.findRoute(position, goal, [blocker])
    if tick == 0:
      doAssert move.action == West
    if tick == 1:
      doAssert move.action != East, "Do not abandon a detour after one step."
    doAssert move.action != Rest
    position = position.neighbor(move.action)
    doAssert position != blocker
    doAssert router.rebuiltColumns == columns
  doAssert position == goal

echo "Detours that initially move away from the goal finish without oscillation."

block:
  let
    router = newRoutes()
    start = tileAt(20, 20)
    goal = tileAt(30, 20)
    blocker = tileAt(21, 20)
  let first = router.findRoute(start, goal, [blocker])
  let position = start.neighbor(first.action)
  let planned = router.findRoute(position, goal, [blocker])
  let blocked = position.neighbor(planned.action)
  let retry = router.findRoute(position, goal, [blocker, blocked])
  doAssert retry.action == Rest or position.neighbor(retry.action) != blocked
  let redirected = router.findRoute(position, position.neighbor(West), [blocker])
  doAssert redirected.action == West

echo "Changed occupancy, failed moves, and new goals discard stale detours."
