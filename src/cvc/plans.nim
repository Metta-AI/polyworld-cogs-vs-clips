import
  std/algorithm,
  common

const MaxWaypoints* = 16

type Plan* = object
  targets*: seq[int32]

proc path*(world: World, start, target: int32): seq[int32] =
  ## Finds a display or manual-order path without invoking a bot policy.
  if start < 0 or target < 0 or start >= TileCount or target >= TileCount or
    world.tiles[target].wall:
      return
  var
    parents: array[TileCount, int32]
    visited: array[TileCount, bool]
    queue: array[TileCount, int32]
    head = 0
    tail = 1
  queue[0] = start
  visited[start] = true
  while head < tail:
    let tile = queue[head]
    inc head
    if tile == target:
      var current = target
      while current != start:
        result.add(current)
        current = parents[current]
      result.add(start)
      result.reverse()
      return
    for action in North .. West:
      let next = tile.neighbor(action)
      if next < 0 or visited[next] or world.tiles[next].wall or
        (next != target and world.tiles[next].station >= 0):
          continue
      visited[next] = true
      parents[next] = tile
      queue[tail] = next
      inc tail

proc order*(plan: var Plan, tile: int32, queue: bool) =
  ## Replaces an order or appends one bounded waypoint.
  if not queue:
    plan.targets.setLen(0)
  if tile >= 0 and tile < TileCount and plan.targets.len < MaxWaypoints:
    plan.targets.add(tile)

proc arrive*(plan: var Plan, world: World, slot: int) =
  ## Completes movement or a successful bump interaction after a real tick.
  if plan.targets.len == 0:
    return
  let
    cog = world.cogs[slot]
    target = plan.targets[0]
  if cog.tile == target or
    (cog.tile.neighbor(cog.direction) == target and cog.feedback in
      {Gathered, Deposited, Equipped, Crafted, Captured, Disrupted}):
      plan.targets.delete(0)

proc action*(plan: Plan, world: World, slot: int): Action =
  ## Converts the next manual waypoint into an ordinary recorded action.
  if plan.targets.len == 0:
    return Rest
  let route = world.path(world.cogs[slot].tile, plan.targets[0])
  if route.len > 1:
    for direction in North .. West:
      if route[0].neighbor(direction) == route[1]:
        return direction
