import common, sims

const
  NeuralInputs = 134 * 13 * 13
  InventoryRoles = [30, 26, 28, 32]
  RoleTags = [14, 9, 17, 16]
  ResourceFeatures = [14, 12, 16, 18]
  ResourceTags = [10, 15, 11, 19]
  TeamTags = [0, 2, 0, 1, 3]
  DirectionFeatures = [0, 130, 132, 131, 133]
  ActionsToLegacy = [0, 1, 4, 2, 3]

type
  NeuralView* = object
    initialized: bool
    tick: int32
    spawn, previous: array[CogCount, int32]
    observed: array[CogCount, int32]
    moved: array[CogCount, bool]
    last*: Actions
    owners: array[TileCount, Owner]
    known: array[TileCount, bool]
  NeuralGrid* = array[NeuralInputs, float32]

proc neuralRole*(slot, requested: int): int =
  ## Resolves one fixed role or the explicit mixed-role lineup.
  if requested == 10:
    [0, 0, 0, 0, 1, 1, 2, 3][slot mod TeamSize]
  else:
    requested

proc prepare(view: var NeuralView, world: World) =
  ## Resets episode memory and caches only within the current tick.
  if not view.initialized or world.tick < view.tick:
    view.initialized = true
    let initial = initWorld(world.seed)
    for slot, cog in initial.cogs:
      view.spawn[slot] = cog.tile
      view.previous[slot] = cog.tile
      view.observed[slot] = -1
  if world.tick != view.tick or world.tick == 0:
    reset(view.known)
    view.tick = world.tick

proc owner(view: var NeuralView, world: World, tile: int32): Owner =
  ## Queries ownership only for requested visible tiles and their edges.
  if tile < 0:
    return Neutral
  if not view.known[tile]:
    view.owners[tile] = world.territory(tile)
    view.known[tile] = true
  view.owners[tile]

proc relative(owner, team: Owner): int =
  ## Uses the source policy's neutral, friendly, other ownership alphabet.
  if owner == Neutral: 0
  elif owner == team: 1
  else: 2

proc neuralGrid*(view: var NeuralView, world: World, slot, requested: int,
    output: var NeuralGrid) =
  ## Builds the reconstructed 134-feature candidate from visible sim state.
  assert slot in 0 ..< CogCount and requested in 0 .. 10
  view.prepare(world)
  reset(output)
  let
    cog = world.cogs[slot]
    role = neuralRole(slot, requested)
  template emit(location, feature, value: untyped) =
    block:
      let
        field = int(feature)
        norm =
          if field == 0 or field == 2 or field == 6: 10.0'f
          elif field in [3, 4] or field in 56 .. 99: 100.0'f
          elif field in 12 .. 55 or field in 100 .. 127: 256.0'f
          elif field == 128: 1.0'f
          elif field == 129: 3.0'f
          elif field in 130 .. 133: 9.0'f
          else: 255.0'f
        cell = int(location)
      output[field * 169 + cell] += float32(value) / (norm + 0.000001'f)
  template inventory(location, feature, amount: untyped) =
    block:
      let count = int(amount)
      if count > 0:
        emit(location, feature, count and 255)
        if count >= 256:
          emit(location, feature + 1, (count shr 8) and 255)
  emit(168, 1, min(255, world.tick * 256 div MaxTicks))
  let last = ActionsToLegacy[ord(view.last[slot])]
  emit(168, 2, last)
  if view.observed[slot] != world.tick:
    view.moved[slot] = cog.tile != view.previous[slot]
    view.previous[slot] = cog.tile
    view.observed[slot] = world.tick
  emit(168, 128, int(view.moved[slot]))
  let
    dx = cog.tile.x - view.spawn[slot].x
    dy = cog.tile.y - view.spawn[slot].y
  if dx > 0: emit(168, 7, dx)
  if dx < 0: emit(168, 8, -dx)
  if dy < 0: emit(168, 9, -dy)
  if dy > 0: emit(168, 10, dy)
  for element in Element:
    inventory(168, 100 + [2, 0, 4, 6][ord(element)],
      world.banks[cog.team][element])
  emit(168, 108 + role * 2, 1)
  emit(168, 129, relative(view.owner(world, cog.tile), cog.team))
  for y in -6'i32 .. 6:
    for x in -6'i32 .. 6:
      let
        tile = tileAt(cog.tile.x + x, cog.tile.y + y)
        cell = int((y + 6) * 13 + x + 6)
      if tile < 0:
        continue
      let territory = view.owner(world, tile)
      for direction in North .. West:
        let neighbor = view.owner(world, tile.neighbor(direction))
        if territory != neighbor:
          emit(cell, DirectionFeatures[ord(direction)],
            relative(territory, cog.team) * 3 + relative(neighbor, cog.team))
      var occupant = -1
      for index, other in world.cogs:
        if other.tile == tile:
          occupant = index
      if occupant >= 0:
        let other = world.cogs[occupant]
        emit(cell, 6, 8)
        emit(cell, 6, 4 + TeamTags[ord(other.team)])
        emit(cell, 0, ord(other.team) - 1)
        emit(cell, 11, occupant)
        inventory(cell, 20, other.hp)
        inventory(cell, 22, other.hearts)
        inventory(cell, 24, other.energy)
        inventory(cell, 34, (if world.tick mod DayLength < 100: 3 else: 1))
        for element in Element:
          inventory(cell, ResourceFeatures[ord(element)], other.cargo[element])
        if other.role != Ungeared:
          inventory(cell, InventoryRoles[ord(other.role) - 1], 1)
        inventory(cell, 36 + neuralRole(occupant, requested) * 2, 1)
      elif world.tiles[tile].wall:
        emit(cell, 6, 20)
      elif world.tiles[tile].station >= 0:
        let station = world.stations[world.tiles[tile].station]
        if station.owner != Neutral:
          emit(cell, 6, 4 + TeamTags[ord(station.owner)])
          if station.kind in {Hub, Junction}:
            emit(cell, 6, TeamTags[ord(station.owner)])
        case station.kind
        of Hub:
          emit(cell, 6, 12)
          for element in Element:
            emit(cell, 56 + [1, 0, 2, 3][ord(element)], HeartCost)
          emit(cell, 78 + 5, 1)
        of Junction:
          emit(cell, 6, 13)
        of Ship:
          emit(cell, 6, 18)
        of Extractor:
          emit(cell, 6, ResourceTags[ord(station.element)])
          inventory(cell, ResourceFeatures[ord(station.element)], station.stock)
          emit(cell, 78 + [1, 0, 2, 3][ord(station.element)],
            (if cog.role == Miner: 10 else: 1))
        of Gear:
          emit(cell, 6, RoleTags[ord(station.role) - 1])
          for element in Element:
            emit(cell, 56 + [1, 0, 2, 3][ord(element)],
              GearCosts[station.role][element])
          emit(cell, 78 + (InventoryRoles[ord(station.role) - 1] - 12) div 2, 1)
