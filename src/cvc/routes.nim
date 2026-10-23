import
  std/heapqueue,
  common, profiles

const
  SearchStates = TileCount * 3
  DetourRadius* = 6
  DetourWidth = DetourRadius * 2 + 1
  DetourTiles* = DetourWidth * DetourWidth

type
  RouteResult* = object
    action*: Action
    distance*: int32
  RouteNode = object
    state, cost, priority: int32
  Routes* = ref object
    base: array[TileCount, bool]
    walk: array[TileCount, bool]
    dirty: array[Width, bool]
    jumps: array[TileCount, array[2, int16]]
    forced: array[TileCount, array[2, uint8]]
    overrides: seq[int32]
    costs: array[SearchStates, int32]
    seen: array[SearchStates, uint32]
    first: array[SearchStates, Action]
    parents: array[SearchStates, int32]
    goalState: int32
    chain: seq[int32]
    localOpen: HeapQueue[RouteNode]
    detourPath: seq[int32]
    detourTarget, detourPosition, detourRemaining: int32
    rebuiltColumns*: int
    detourExpansions*: int
    crowded*: bool
    stamp: uint32
    open: HeapQueue[RouteNode]

proc `<`(a, b: RouteNode): bool =
  ## Breaks equal priorities deterministically toward deeper paths.
  if a.priority != b.priority:
    a.priority < b.priority
  elif a.cost != b.cost:
    a.cost > b.cost
  else:
    a.state < b.state

proc newRoutes*(): Routes =
  ## Starts with optimistic unknown terrain and reusable search storage.
  new(result)
  for tile in 0 ..< TileCount:
    result.base[tile] = true
    result.walk[tile] = true
  for x in 0 ..< Width:
    result.dirty[x] = true

proc setWalk(routes: Routes, tile: int32, value: bool) =
  ## Invalidates only columns whose vertical jump rules can change.
  if routes.walk[tile] == value:
    return
  routes.walk[tile] = value
  for x in max(0, tile.x - 1) .. min(Width - 1, tile.x + 1):
    routes.dirty[x] = true

proc remember*(routes: Routes, tile: int32, passable: bool) =
  ## Updates remembered terrain without exposing unseen map cells.
  assert tile >= 0 and tile < TileCount
  if routes.base[tile] == passable:
    return
  routes.base[tile] = passable
  if tile notin routes.overrides:
    routes.setWalk(tile, passable)

proc passable(routes: Routes, x, y: int32): bool =
  ## Treats every position beyond the fixed board as blocked.
  let tile = tileAt(x, y)
  tile >= 0 and routes.walk[tile]

proc prepare(routes: Routes) {.measure.} =
  ## Precomputes JPS4 vertical jumps in the columns changed since last query.
  for x in 0 ..< Width:
    if not routes.dirty[x]:
      continue
    routes.dirty[x] = false
    inc routes.rebuiltColumns
    for direction in 0 ..< 2:
      let dy = if direction == 0: -1'i32 else: 1'i32
      for offset in 0 ..< Height:
        let
          y = (if direction == 0: offset else: Height - 1 - offset).int32
          tile = tileAt(x.int32, y)
        routes.forced[tile][direction] = 0
        if routes.walk[tile]:
          for side in 0 ..< 2:
            let dx = if side == 0: -1'i32 else: 1'i32
            if routes.passable(x.int32 + dx, y) and
              not routes.passable(x.int32 + dx, y - dy):
                routes.forced[tile][direction] =
                  routes.forced[tile][direction] or uint8(1 shl side)
        let next = tileAt(x.int32, y + dy)
        if not routes.walk[tile] or next < 0 or not routes.walk[next]:
          routes.jumps[tile][direction] = 0
        elif routes.forced[next][direction] != 0:
          routes.jumps[tile][direction] = 1
        else:
          let previous = routes.jumps[next][direction]
          routes.jumps[tile][direction] =
            if previous > 0:
              previous + 1
            else:
              previous - 1

proc terrainRoute(
  routes: Routes,
  start, target: int32
): RouteResult {.measure.} =
  ## Searches remembered terrain without ever inserting moving obstacles.
  result.distance = -1
  if start < 0 or start >= TileCount or target < 0 or target >= TileCount:
    return
  if start == target:
    return RouteResult(action: Rest, distance: 0)

  var changed: seq[int32] = routes.overrides
  routes.overrides.setLen(0)
  for tile in [start, target]:
    if tile notin routes.overrides:
      routes.overrides.add(tile)
  for tile in routes.overrides:
    if tile notin changed:
      changed.add(tile)
  for tile in changed:
    let walk = tile == start or tile == target or routes.base[tile]
    routes.setWalk(tile, walk)
  if not routes.walk[target]:
    return
  routes.prepare()
  if routes.stamp == uint32.high:
    routes.seen = default(typeof(routes.seen))
    routes.stamp = 0
  inc routes.stamp
  routes.open.clear()
  let initial = start * 3
  routes.seen[initial] = routes.stamp
  routes.costs[initial] = 0
  routes.first[initial] = Rest
  routes.parents[initial] = -1
  routes.open.push(RouteNode(state: initial, cost: 0))
  while routes.open.len > 0:
    let current = routes.open.pop()
    if current.cost != routes.costs[current.state]:
      continue
    let
      tile = current.state div 3
      arrival = current.state mod 3
    if tile == target:
      routes.goalState = current.state
      return RouteResult(
        action: routes.first[current.state],
        distance: current.cost
      )
    for direction in [North, East, South, West]:
      var
        next = -1'i32
        distance = 1'i32
        nextArrival = 0'i32
      if direction in {East, West}:
        let side = if direction == West: 0 else: 1
        if arrival != 0 and
          (routes.forced[tile][arrival - 1] and uint8(1 shl side)) == 0:
            continue
        next = tile.neighbor(direction)
        if next < 0 or not routes.walk[next]:
          continue
      else:
        let vertical = if direction == North: 0 else: 1
        nextArrival = int32(vertical + 1)
        if arrival != 0 and arrival != nextArrival:
          continue
        let
          jump = routes.jumps[tile][vertical].int32
          dy = if direction == North: -1'i32 else: 1'i32
          goalDistance = (target.y - tile.y) * dy
        if target.x == tile.x and goalDistance > 0 and
          goalDistance <= abs(jump):
            distance = goalDistance
        elif jump > 0:
          distance = jump
        else:
          continue
        next = tileAt(tile.x, tile.y + dy * distance)
      let
        state = next * 3 + nextArrival
        cost = current.cost + distance
      if routes.seen[state] == routes.stamp and routes.costs[state] <= cost:
        continue
      routes.seen[state] = routes.stamp
      routes.costs[state] = cost
      routes.parents[state] = current.state
      routes.first[state] =
        if tile == start:
          direction
        else:
          routes.first[current.state]
      routes.open.push(RouteNode(
        state: state,
        cost: cost,
        priority: cost + abs(next.x - target.x) + abs(next.y - target.y)
      ))

proc waypoint(
  routes: Routes,
  start: int32,
  occupied: openArray[int32]
): tuple[tile, steps: int32] =
  ## Selects a free rejoin point within six steps along the terrain path.
  routes.chain.setLen(0)
  var state = routes.goalState
  while state >= 0:
    routes.chain.add(state div 3)
    state = routes.parents[state]
  result.tile = -1
  var
    tile = start
    steps = 0'i32
  for i in countdown(routes.chain.high - 1, 0):
    let endpoint = routes.chain[i]
    while tile != endpoint and steps < DetourRadius:
      let
        dx = cmp(endpoint.x, tile.x).int32
        dy = cmp(endpoint.y, tile.y).int32
      tile = tileAt(tile.x + dx, tile.y + dy)
      inc steps
      if tile notin occupied:
        result = (tile, steps)
    if steps >= DetourRadius:
      break

proc detour(
  routes: Routes,
  start, goal: int32,
  occupied: openArray[int32]
): RouteResult {.measure.} =
  ## Runs bounded local A* around cogs without modifying terrain or jumps.
  result.distance = -1
  var
    costs: array[DetourTiles, int32]
    seen, closed: array[DetourTiles, bool]
    first: array[DetourTiles, Action]
    parents: array[DetourTiles, int32]
  proc index(tile: int32): int =
    ## Maps a nearby world cell into the local fixed-size search arrays.
    int((tile.y - start.y + DetourRadius) * DetourWidth +
      tile.x - start.x + DetourRadius)
  let initial = index(start)
  seen[initial] = true
  routes.localOpen.clear()
  routes.localOpen.push(RouteNode(state: start))
  while routes.localOpen.len > 0 and routes.detourExpansions < DetourTiles:
    let
      current = routes.localOpen.pop()
      tile = current.state
      at = index(tile)
    if closed[at] or current.cost != costs[at]:
      continue
    closed[at] = true
    inc routes.detourExpansions
    if tile == goal:
      routes.detourPath.setLen(0)
      var previous = tile
      while previous != start:
        routes.detourPath.add(previous)
        previous = parents[index(previous)]
      return RouteResult(action: first[at], distance: current.cost)
    for action in [North, East, South, West]:
      let next = tile.neighbor(action)
      if next < 0 or abs(next.x - start.x) > DetourRadius or
        abs(next.y - start.y) > DetourRadius or
        not routes.walk[next] or next in occupied:
          continue
      let
        nextIndex = index(next)
        cost = current.cost + 1
      if closed[nextIndex] or (seen[nextIndex] and costs[nextIndex] <= cost):
        continue
      seen[nextIndex] = true
      costs[nextIndex] = cost
      parents[nextIndex] = tile
      first[nextIndex] =
        if tile == start:
          action
        else:
          first[at]
      routes.localOpen.push(RouteNode(
        state: next,
        cost: cost,
        priority: cost + abs(next.x - goal.x) + abs(next.y - goal.y)
      ))

proc findRoute*(
  routes: Routes,
  start, target: int32,
  occupied: openArray[int32]
): RouteResult {.measure.} =
  ## Follows terrain JPS+ and completes bounded detours around visible cogs.
  routes.detourExpansions = 0
  result = routes.terrainRoute(start, target)
  routes.crowded = result.action != Rest and
    start.neighbor(result.action) in occupied
  if routes.detourPath.len > 0:
    let next = routes.detourPath[^1]
    if target == routes.detourTarget and start == routes.detourPosition and
      occupied.len > 0 and next notin occupied and routes.walk[next]:
        for action in [North, East, South, West]:
          if start.neighbor(action) == next:
            result = RouteResult(
              action: action,
              distance: int32(routes.detourPath.len) + routes.detourRemaining
            )
            routes.detourPath.setLen(routes.detourPath.len - 1)
            routes.detourPosition = next
            return
    routes.detourPath.setLen(0)
  if result.action == Rest or start.neighbor(result.action) notin occupied:
    return
  let rejoin = routes.waypoint(start, occupied)
  if rejoin.tile < 0:
    return RouteResult(action: Rest, distance: -1)
  let local = routes.detour(start, rejoin.tile, occupied)
  if local.distance < 0:
    return RouteResult(action: Rest, distance: -1)
  routes.detourTarget = target
  routes.detourPosition = start.neighbor(local.action)
  routes.detourRemaining = result.distance - rejoin.steps
  routes.detourPath.setLen(routes.detourPath.len - 1)
  result.action = local.action
  result.distance += local.distance - rejoin.steps
