import
  std/[monotimes, times, strformat]

include ../src/cvc/bots

var
  queries, differing, detours, rebuiltColumns: int
  bfsTime, jpsTime: int64

proc referenceDistance(brain: Brain, target: int32): int32 =
  ## Checks shortest distance independently of jump tables and pruning.
  let start = brain.world.cogs[brain.slot].tile
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
    for action in [North, East, South, West]:
      let next = tile.neighbor(action)
      if next < 0 or seen[next]:
        continue
      if next == target:
        return depths[tile] + 1
      if brain.memory.seen[next] and
        (brain.memory.tiles[next].wall or
        brain.memory.tiles[next].station >= 0):
          continue
      seen[next] = true
      depths[next] = depths[tile] + 1
      queue[tail] = next
      inc tail
  -1

proc compareRoute(brain: Brain, target: int32) =
  ## Compares both searches on the exact queries of an unchanged BFS match.
  let start = brain.world.cogs[brain.slot].tile
  if target < 0 or target == start:
    return
  inc queries
  let beforeBfs = getMonoTime()
  let reference = brain.routeBfs(target)
  bfsTime += (getMonoTime() - beforeBfs).inNanoseconds

  let beforeJps = getMonoTime()
  var
    occupied: array[CogCount - 1, int32]
    count = 0
  for i, cog in brain.world.cogs:
    if i != brain.slot and brain.world[].visible(brain.slot, cog.tile):
      occupied[count] = cog.tile
      inc count
  let columns = brain.navigation.rebuiltColumns
  let actual = brain.navigation.findRoute(
    start, target, occupied.toOpenArray(0, count - 1)
  )
  jpsTime += (getMonoTime() - beforeJps).inNanoseconds
  rebuiltColumns += brain.navigation.rebuiltColumns - columns
  if brain.navigation.detourExpansions > 0:
    inc detours
  let stableColumns = brain.navigation.rebuiltColumns
  let terrain = brain.navigation.findRoute(start, target, [])
  doAssert terrain.distance == brain.referenceDistance(target)
  doAssert brain.navigation.rebuiltColumns == stableColumns
  if actual.action != Rest:
    doAssert start.neighbor(actual.action) notin
      occupied.toOpenArray(0, count - 1)
  if actual.action != reference:
    inc differing

routeProbe = compareRoute
var world = initWorld(1)
let policies = newBots()
for tick in 0 ..< MaxTicks:
  world.tick(policies.decide(world))
echo &"Queries: {queries}"
echo &"BFS: {bfsTime.float64 / 1e6:.3f} ms"
echo &"CVC JPS+ including local avoidance: {jpsTime.float64 / 1e6:.3f} ms"
echo &"Different first-step candidates: {differing}"
echo &"Local detours: {detours}, rebuilt terrain columns: {rebuiltColumns}"
echo "Final baseline hash: ", world.stateHash()
