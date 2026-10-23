import
  polyworld/[rngs, hashes],
  common, maps

export common

proc root*(value: int64): int32 =
  ## Computes floor square root using bounded integer arithmetic.
  var
    low = 0'i64
    high = min(value, 1_000_000'i64) + 1
  while low + 1 < high:
    let middle = (low + high) div 2
    if middle * middle <= value:
      low = middle
    else:
      high = middle
  int32(low)

proc territory*(world: World, tile: int32): Owner =
  ## Sums fixed-point radial influence, with neutral ownership on ties.
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
  if strengths[Cogs] > strengths[Clips]:
    Cogs
  elif strengths[Clips] > strengths[Cogs]:
    Clips
  else:
    Neutral

proc linked*(world: World, tile: int32, owner: Owner): bool =
  ## Checks the capture reach of a team's current network.
  for station in world.stations:
    if station.owner == owner and station.kind in {Hub, Junction, Ship}:
      let radius =
        if station.kind == Hub: HubAlignRadius else: AlignRadius
      if station.tile.distance2(tile) <= radius * radius:
        return true

proc reconnect*(world: var World) =
  ## Neutralizes junctions disconnected from their faction's root.
  var reached: array[MaxStations, bool]
  for i, station in world.stations:
    reached[i] = station.kind in {Hub, Ship}
  var changed = true
  while changed:
    changed = false
    for i, station in world.stations:
      if reached[i] or station.owner == Neutral or
        station.kind != Junction:
          continue
      for j, other in world.stations:
        if reached[j] and other.owner == station.owner and
          other.tile.distance2(station.tile) <= HubAlignRadius * HubAlignRadius:
            reached[i] = true
            changed = true
            break
  for i in 0 ..< world.stations.len:
    if world.stations[i].kind == Junction and not reached[i]:
      world.stations[i].owner = Neutral

proc deposit(world: var World, slot: int): bool =
  ## Transfers cargo into the shared bank without losing overflow.
  var total = 0'i32
  for amount in world.bank:
    total += amount
  for element in Element:
    let amount = min(world.cogs[slot].cargo[element], 10000 - total)
    world.bank[element] += amount
    world.cogs[slot].cargo[element] -= amount
    total += amount
    result = result or amount > 0
  if result:
    world.cogs[slot].feedback = Deposited

proc useStation*(world: var World, slot, index: int) =
  ## Resolves a bump interaction against one station.
  let station = world.stations[index]
  case station.kind
  of Hub:
    if world.deposit(slot):
      return
    if world.cogs[slot].hearts >= HeartLimit:
      return
    if world.hearts > 0:
      dec world.hearts
      inc world.cogs[slot].hearts
      world.cogs[slot].feedback = Crafted
    else:
      for amount in world.bank:
        if amount < HeartCost:
          return
      for element in Element:
        world.bank[element] -= HeartCost
      inc world.cogs[slot].hearts
      world.cogs[slot].feedback = Crafted
  of Extractor:
    let
      cog = world.cogs[slot]
      rate = if cog.role == Miner: 10'i32 else: 1'i32
      amount = min(rate, min(station.stock, cog.role.capacity - cog.carried))
    if amount > 0:
      world.cogs[slot].cargo[station.element] += amount
      world.stations[index].stock -= amount
      world.cogs[slot].feedback = Gathered
      if world.stations[index].stock == 0:
        world.tiles[station.tile].station = -1
  of Gear:
    if world.cogs[slot].role == station.role:
      return
    let cost = GearCosts[station.role]
    for element in Element:
      if world.bank[element] < cost[element]:
        return
    for element in Element:
      world.bank[element] -= cost[element]
    world.cogs[slot].role = station.role
    world.cogs[slot].hp = min(world.cogs[slot].hp, station.role.maxHp)
    world.cogs[slot].energy = min(
      world.cogs[slot].energy, station.role.maxEnergy
    )
    world.cogs[slot].feedback = Equipped
  of Junction:
    if station.owner == Cogs:
      discard world.deposit(slot)
    elif world.cogs[slot].hearts > 0:
      case world.cogs[slot].role
      of Scrambler:
        if station.owner == Clips:
          dec world.cogs[slot].hearts
          world.stations[index].owner = Neutral
          world.cogs[slot].feedback = Disrupted
          world.reconnect()
      of Aligner:
        if station.owner == Neutral and world.linked(station.tile, Cogs):
          dec world.cogs[slot].hearts
          world.stations[index].owner = Cogs
          world.cogs[slot].feedback = Captured
      else:
        discard
  of Ship:
    discard

proc act(world: var World, slot: int, action: Action) =
  ## Resolves movement or interaction for one Cog in lockstep order.
  world.cogs[slot].feedback = Idle
  if action == Rest:
    return
  world.cogs[slot].direction = action
  if world.cogs[slot].energy < MoveCost:
    world.cogs[slot].feedback = Exhausted
    return
  let tile = world.cogs[slot].tile.neighbor(action)
  if tile < 0 or world.tiles[tile].wall:
    world.cogs[slot].feedback = Blocked
    return
  for other in world.cogs:
    if other.tile == tile:
      world.cogs[slot].feedback = Blocked
      return
  world.cogs[slot].energy -= MoveCost
  let index = world.tiles[tile].station
  if index >= 0:
    world.useStation(slot, index)
  else:
    world.cogs[slot].tile = tile
    world.cogs[slot].feedback = Moved

proc frontier(world: World, ship: Station): array[MaxStations, bool] =
  ## Follows one ship's lane through junctions within expansion range.
  for i, station in world.stations:
    result[i] = station.kind == Ship and station.lane == ship.lane
  var changed = true
  while changed:
    changed = false
    for i, station in world.stations:
      if result[i] or station.kind != Junction or
        station.owner != Clips or station.lane != ship.lane:
          continue
      for j, other in world.stations:
        if result[j] and
          other.tile.distance2(station.tile) <= AlignRadius * AlignRadius:
            result[i] = true
            changed = true
            break

proc spread*(world: var World) =
  ## Expands each ship's connected Clips frontier at fixed intervals.
  if world.tick < ClipsStart or
    (world.tick - ClipsStart) mod ClipsPeriod != 0:
      return
  for ship in world.stations:
    if ship.kind != Ship:
      continue
    for targetOwner in [Neutral, Cogs]:
      let reached = world.frontier(ship)
      var
        target = -1
        distance = int32.high
      for i, station in world.stations:
        if station.kind != Junction or station.owner != targetOwner:
          continue
        var reachable = false
        for j, other in world.stations:
          if reached[j] and
            other.tile.distance2(station.tile) <= AlignRadius * AlignRadius:
              reachable = true
              break
        if reachable:
          let candidate = ship.tile.distance2(station.tile)
          if candidate < distance:
            target = i
            distance = candidate
      if target >= 0:
        world.stations[target].owner =
          if targetOwner == Neutral: Clips else: Neutral
        world.stations[target].lane =
          if targetOwner == Neutral: ship.lane else: 0
        world.reconnect()

proc tick*(world: var World, actions: Actions) =
  ## Applies actions, Clips events, territory effects, and integer scoring.
  if world.tick >= MaxTicks:
    return
  var order: array[CogCount, int]
  for i in 0 ..< CogCount:
    order[i] = i
  for i in countdown(CogCount - 1, 1):
    swap(order[i], order[world.rng.below(int32(i + 1))])
  for slot in order:
    world.act(slot, actions[slot])
  world.spread()
  let solar = if world.tick mod DayLength < DayLength div 2: 3 else: 1
  for i in 0 ..< CogCount:
    var cog = addr world.cogs[i]
    cog.hp = max(0, cog.hp - 1)
    cog.energy = min(cog.role.maxEnergy, cog.energy + int32(solar))
    case world.territory(cog.tile)
    of Cogs:
      cog.hp = min(cog.role.maxHp, cog.hp + 100)
      cog.energy = min(cog.role.maxEnergy, cog.energy + 100)
    of Clips:
      cog.hp = max(0, cog.hp - 1)
    of Neutral:
      discard
    if cog.hp == 0:
      cog.role = Ungeared
      cog.hearts = 0
      cog.energy = min(cog.energy, cog.role.maxEnergy)
      cog.feedback = Broken
  for station in world.stations:
    if station.kind == Junction:
      case station.owner
      of Cogs: inc world.score
      of Clips: inc world.clipsScore
      of Neutral: discard
  inc world.tick

proc stateHash*(world: World): uint64 =
  ## Hashes all authoritative state without native layout dependence.
  uint64(hashy(world))

proc initWorld*(seed: int32): World =
  ## Initializes the sole supported scenario.
  generate(seed)
