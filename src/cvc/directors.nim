import
  polyworld/rngs,
  common, sims

type Director* = object
  enabled*: bool
  initialized: bool
  tick: int32
  target*: int
  held: float64
  quiet: float64
  interest: array[CogCount, float32]
  owners: array[MaxStations, Owner]
  stationCount: int
  rng: Rng
  areas*: array[CogCount, int32]

proc reset*(director: var Director) =
  ## Clears camera history after a seek without changing its enabled state.
  let enabled = director.enabled
  director = Director(enabled: enabled, target: -1)

proc changedArea*(before, after: World): int32 =
  ## Counts playable tiles changing owner, including territory becoming neutral.
  var candidates: array[TileCount, bool]
  for i, station in after.stations:
    if i >= before.stations.len or station.owner == before.stations[i].owner:
      continue
    let radius = if station.kind == Hub: HubRadius else: TerritoryRadius
    for y in max(0'i32, station.tile.y - radius) ..
      min(Height - 1, station.tile.y + radius):
        for x in max(0'i32, station.tile.x - radius) ..
          min(Width - 1, station.tile.x + radius):
            candidates[tileAt(x, y)] = true
  for tile in 0 ..< TileCount:
    if candidates[tile] and not after.tiles[tile].wall and
      before.territory(tile.int32) != after.territory(tile.int32):
        inc result

proc measureAreas(director: var Director, world: World) =
  ## Reconstructs junction events in tick order on private station snapshots.
  director.areas = default(typeof(director.areas))
  if director.initialized and world.tick == director.tick + 1 and
    world.stations.len == director.stationCount:
      var changed = false
      for i, station in world.stations:
        if station.owner != director.owners[i]:
          changed = true
          break
      if changed:
        var
          snapshot = world
          order: array[CogCount, int]
          rng = director.rng
        for i in 0 ..< snapshot.stations.len:
          snapshot.stations[i].owner = director.owners[i]
        for i in 0 ..< CogCount:
          order[i] = i
        for i in countdown(CogCount - 1, 1):
          swap(order[i], order[rng.below(int32(i + 1))])
        for slot in order:
          let cog = world.cogs[slot]
          if cog.feedback notin {Captured, Disrupted}:
            continue
          let tile = cog.tile.neighbor(cog.direction)
          if tile < 0:
            continue
          let index = world.tiles[tile].station
          if index < 0 or snapshot.stations[index].kind != Junction:
            continue
          let before = snapshot
          if cog.feedback == Captured:
            snapshot.stations[index].owner = cog.team
          else:
            snapshot.stations[index].owner = Neutral
            snapshot.reconnect()
          director.areas[slot] = changedArea(before, snapshot)
  director.stationCount = world.stations.len
  for i, station in world.stations:
    director.owners[i] = station.owner
  director.rng = world.rng

proc observe*(director: var Director, world: World) =
  ## Scores actual interactions and approaching junctions without changing state.
  if not director.initialized or world.tick < director.tick:
    director.reset()
  elif world.tick == director.tick:
    return
  director.measureAreas(world)
  director.initialized = true
  director.tick = world.tick
  for i, cog in world.cogs:
    director.interest[i] *= 0.94'f
    let activity =
      case cog.feedback
      of Captured, Disrupted: 12'f + director.areas[i].float32 * 0.5'f
      of Gathered: 35'f
      of Deposited: 30'f
      of Crafted: 25'f
      of Equipped: 20'f
      of Moved: 3'f
      else: 0'f
    director.interest[i] = max(director.interest[i], activity)
    if cog.feedback == Moved and cog.hearts > 0 and
      cog.role in {Aligner, Scrambler}:
        for station in world.stations:
          if station.kind != Junction or station.owner == cog.team:
            continue
          if (cog.role == Aligner and station.owner != Neutral) or
            (cog.role == Scrambler and station.owner == Neutral):
              continue
          let distance = cog.tile.distance2(station.tile)
          if distance <= 36:
            director.interest[i] = max(
              director.interest[i], 18'f - distance.float32 * 0.25'f
            )

proc choose*(director: var Director, elapsed: float64): bool =
  ## Holds readable shots and switches away from inactivity or to better action.
  if not director.enabled:
    return false
  director.held += elapsed
  var best = 0
  for i in 1 ..< CogCount:
    if director.interest[i] > director.interest[best]:
      best = i
  if director.target >= 0:
    if director.interest[director.target] < 8:
      director.quiet += elapsed
    else:
      director.quiet = 0
    if best == director.target:
      return false
    if director.held < 4:
      return false
    if director.quiet < 2 and director.held < 12 and
      director.interest[best] < director.interest[director.target] + 45:
        return false
    if director.interest[best] <= director.interest[director.target]:
      return false
  director.target = best
  director.held = 0
  director.quiet = 0
  true
