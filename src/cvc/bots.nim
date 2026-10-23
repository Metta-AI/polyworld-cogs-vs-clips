import
  bassy,
  polyworld/policyhosts,
  sims

const BaselineSource* = staticRead("../../players/base.bas")

type
  Memory = object
    seen: array[TileCount, bool]
    tiles: array[TileCount, Tile]
    stations: seq[Station]
  Brain = ref object
    runtime: Runtime
    memory: Memory
    world: ptr World
    slot: int
    action: Action
    error: string
  Bots* = ref object
    brains: array[CogCount, Brain]

proc remember(brain: Brain) =
  ## Updates only tiles and stations inside the current observation window.
  let
    world = brain.world[]
    cog = world.cogs[brain.slot]
  if brain.memory.stations.len == 0:
    brain.memory.stations.setLen(world.stations.len)
    for station in brain.memory.stations.mitems:
      station.tile = -1
  for dy in -ViewRadius .. ViewRadius:
    for dx in -ViewRadius .. ViewRadius:
      let tile = tileAt(cog.tile.x + dx, cog.tile.y + dy)
      if tile < 0:
        continue
      let previous = brain.memory.tiles[tile].station
      if brain.memory.seen[tile] and previous >= 0 and
        world.tiles[tile].station < 0:
          brain.memory.stations[previous].stock = 0
      brain.memory.seen[tile] = true
      brain.memory.tiles[tile] = world.tiles[tile]
      let index = world.tiles[tile].station
      if index >= 0:
        brain.memory.stations[index] = world.stations[index]

proc route(brain: Brain, target: int32): Action =
  ## Routes through remembered terrain to an adjacent bump interaction.
  let start = brain.world.cogs[brain.slot].tile
  if target == start or target < 0:
    return Rest
  var
    queue: array[TileCount, int32]
    visited: array[TileCount, bool]
    first: array[TileCount, Action]
    head = 0
    tail = 1
  queue[0] = start
  visited[start] = true
  for i, cog in brain.world.cogs:
    if i != brain.slot and brain.world[].visible(brain.slot, cog.tile):
      visited[cog.tile] = true
  while head < tail:
    let tile = queue[head]
    inc head
    for offset in 0 ..< 4:
      let
        direction = Action(1 + (offset + brain.slot) mod 4)
        next = tile.neighbor(direction)
      if next < 0 or visited[next]:
        continue
      let action = if tile == start: direction else: first[tile]
      if next == target:
        return action
      if brain.memory.seen[next] and
        (brain.memory.tiles[next].wall or
        brain.memory.tiles[next].station >= 0):
          continue
      visited[next] = true
      first[next] = action
      queue[tail] = next
      inc tail

proc baseline(brain: Brain): Action =
  ## Chooses a role task using remembered observations and the shared bank.
  let
    world = brain.world[]
    cog = world.cogs[brain.slot]
    desired = [Miner, Miner, Miner, Miner, Aligner, Aligner,
      Scrambler, Scout][brain.slot]
  var
    target = -1'i32
    distance = int32.high
  proc consider(tile: int32) =
    ## Keeps the closest valid remembered target.
    if tile < 0:
      return
    let candidate = cog.tile.distance2(tile)
    if candidate < distance:
      target = tile
      distance = candidate
  if cog.hp < 25:
    consider(tileAt(44, 44))
  elif cog.role != desired:
    for station in brain.memory.stations:
      if station.kind == Gear and station.role == desired:
        consider(station.tile)
    if target < 0:
      let locations = [tileAt(37, 44), tileAt(44, 37),
        tileAt(44, 51), tileAt(51, 44)]
      consider(locations[[Miner, Aligner, Scout, Scrambler].find(desired)])
  elif cog.carried >= cog.role.capacity or
    (cog.role notin {Miner, Scout} and cog.carried > 0):
      consider(tileAt(44, 44))
      for station in brain.memory.stations:
        if station.kind == Junction and station.owner == Cogs:
          consider(station.tile)
  elif cog.role in {Aligner, Scrambler} and cog.hearts == 0:
    consider(tileAt(44, 44))
  elif cog.role in {Miner, Scout}:
    let wanted = Element(brain.slot mod 4)
    for station in brain.memory.stations:
      if station.kind == Extractor and station.stock > 0 and
        station.element == wanted:
          consider(station.tile)
  else:
    for station in brain.memory.stations:
      if station.kind != Junction or station.tile < 0:
        continue
      if cog.role == Scrambler and station.owner == Clips:
        consider(station.tile)
      elif cog.role == Aligner and station.owner == Neutral:
        var reachable = station.tile.distance2(tileAt(44, 44)) <=
          HubAlignRadius * HubAlignRadius
        for other in brain.memory.stations:
          if other.tile >= 0 and other.owner == Cogs and
            other.kind == Junction and
            other.tile.distance2(station.tile) <= AlignRadius * AlignRadius:
              reachable = true
        if reachable:
          consider(station.tile)
  if target < 0:
    for tile in 0'i32 ..< TileCount:
      if not brain.memory.seen[tile] and tile.x > 0 and tile.y > 0 and
        tile.x < Width - 1 and tile.y < Height - 1:
          consider(tile)
  result = brain.route(target)
  if cog.feedback == Blocked and world.tick mod 5 == 0:
    result = Action(1 + (world.tick div 5 + int32(brain.slot)) mod 4)

proc host(brain: Brain): Host =
  ## Registers the fixed BASIC observation and action boundary.
  result = initPolicyHost(brain.slot)
  proc selfProc(args: openArray[int32]): int32 =
    ## Reads one scalar field of the acting Cog.
    let cog = brain.world.cogs[brain.slot]
    case args[0]
    of 0: int32(brain.slot)
    of 1: brain.world.tick
    of 2: cog.tile.x
    of 3: cog.tile.y
    of 4: int32(cog.role)
    of 5: cog.hp
    of 6: cog.energy
    of 7: cog.hearts
    else: 0
  proc bankProc(args: openArray[int32]): int32 =
    ## Reads shared bank inventory by element index.
    if args[0] in 0 .. 3: brain.world.bank[Element(args[0])] else: 0
  proc cargoProc(args: openArray[int32]): int32 =
    ## Reads carried inventory by element index.
    if args[0] in 0 .. 3:
      brain.world.cogs[brain.slot].cargo[Element(args[0])]
    else: 0
  proc tileProc(args: openArray[int32]): int32 =
    ## Reads a visible tile, returning minus one outside vision.
    let tile = tileAt(args[0], args[1])
    if not brain.world[].visible(brain.slot, tile):
      return -1
    if brain.world.tiles[tile].wall:
      return 1
    let station = brain.world.tiles[tile].station
    if station < 0: 0 else: int32(brain.world.stations[station].kind) + 2
  proc ownerProc(args: openArray[int32]): int32 =
    ## Reads visible territory ownership.
    let tile = tileAt(args[0], args[1])
    if brain.world[].visible(brain.slot, tile):
      int32(brain.world[].territory(tile))
    else: -1
  proc stationProc(args: openArray[int32]): int32 =
    ## Reads a visible station field without exposing distant objects.
    let tile = tileAt(args[0], args[1])
    if not brain.world[].visible(brain.slot, tile):
      return -1
    let index = brain.world.tiles[tile].station
    if index < 0:
      return -1
    let station = brain.world.stations[index]
    case args[2]
    of 0: int32(station.kind)
    of 1: int32(station.owner)
    of 2: int32(station.element)
    of 3: station.stock
    of 4: int32(station.role)
    else: -1
  proc cogProc(args: openArray[int32]): int32 =
    ## Reads another Cog only while it is inside the observation window.
    let slot = args[0]
    if slot notin 0 ..< CogCount:
      return -1
    let cog = brain.world.cogs[slot]
    if not brain.world[].visible(brain.slot, cog.tile):
      return -1
    case args[1]
    of 0: cog.tile.x
    of 1: cog.tile.y
    of 2: int32(cog.role)
    of 3: cog.hp
    else: -1
  proc actProc(args: openArray[int32]): int32 =
    ## Queues a cardinal action, treating invalid input as rest.
    if args[0] in 0 .. 4:
      brain.action = Action(args[0])
    0
  proc autoProc(args: openArray[int32]): int32 =
    ## Returns the bundled observation-limited baseline action.
    int32(brain.baseline())
  discard result.addFunction("self", 1, selfProc, 1)
  discard result.addFunction("bank", 1, bankProc, 1)
  discard result.addFunction("cargo", 1, cargoProc, 1)
  discard result.addFunction("tile", 2, tileProc, 1)
  discard result.addFunction("owner", 2, ownerProc, 1)
  discard result.addFunction("station", 3, stationProc, 1)
  discard result.addFunction("cog", 2, cogProc, 1)
  discard result.addFunction("act", 1, actProc, 1)
  discard result.addFunction("baseline", 0, autoProc, TileCount * 4)

proc newBots*(source = BaselineSource): Bots =
  ## Compiles the policy once and creates eight independent runtimes.
  new result
  var limits = defaultLimits()
  limits.maxInstructions = 100_000
  limits.maxWorkUnits = 100_000
  limits.maxPrintBytes = 1024
  limits.maxPrintEvents = 16
  let schema = Brain(slot: 0).host()
  try:
    let program = compile(source, schema, limits)
    for i in 0 ..< CogCount:
      let brain = Brain(slot: i)
      brain.runtime = initRuntime(program, brain.host(), limits)
      result.brains[i] = brain
  except BasicError as error:
    fail("policy compilation failed: " & error.msg)

proc decide*(bots: Bots, world: var World): Actions =
  ## Runs all policies against the same pre-tick state.
  for i, brain in bots.brains:
    brain.world = addr world
    brain.remember()
    brain.action = Rest
    if brain.error.len == 0:
      try:
        brain.runtime.restart()
        discard brain.runtime.run()
      except BasicError as error:
        brain.error = error.msg
        echo "Cog ", i, " policy stopped: ", error.msg
    result[i] = brain.action
    brain.world = nil

proc policyError*(bots: Bots, slot: int): string =
  ## Reports a policy failure without affecting deterministic simulation.
  bots.brains[slot].error
