import
  std/[monotimes, times],
  sims, replays, pipes, tracks

const ScrubSegments* = 20

type
  Exploration* = array[CogCount, array[TileCount, bool]]
  ScrubPoint* = object
    world*: World
    explored*: Exploration
    tracks*: Tracks
    pipes*: PipeSnapshot
  ScrubCache* = object
    duration*: int32
    points*: seq[ScrubPoint]
    builder: Session
    explored: Exploration
    tracks: Tracks
    pipes: PipeSnapshot
    section: int

proc observeExploration*(explored: var Exploration, world: World) =
  ## Accumulates bounded fog history from the simulation's current positions.
  for i, cog in world.cogs:
    for dy in -ViewRadius .. ViewRadius:
      for dx in -ViewRadius .. ViewRadius:
        let tile = tileAt(cog.tile.x + dx, cog.tile.y + dy)
        if tile >= 0 and world.visible(i, tile):
          explored[i][tile] = true

proc complete*(cache: ScrubCache): bool =
  ## Reports whether all replay checkpoints have been prepared.
  cache.points.len > 0 and cache.points[^1].world.tick == cache.duration

proc progress*(cache: ScrubCache): int32 =
  ## Returns the indexed tick for a lightweight loading indicator.
  if cache.builder == nil:
    return 0
  cache.builder.world.tick

proc beginScrubs*(tape: Replay): ScrubCache =
  ## Starts an index without replacing the displayed pipe state.
  let visiblePipes = capturePipes()
  defer:
    restorePipes(visiblePipes)
  result.builder = fromReplay(tape)
  result.duration = int32(tape.hashes.len)
  result.section = 1
  resetPipegridState()
  updatePipegridState(result.builder.world)
  result.explored.observeExploration(result.builder.world)
  result.tracks.observeTracks(result.builder.world)
  result.pipes = capturePipes()
  result.points.add ScrubPoint(
    world: result.builder.world,
    explored: result.explored,
    tracks: result.tracks,
    pipes: result.pipes
  )

proc extendScrubs*(cache: var ScrubCache, milliseconds = 4) =
  ## Builds a bounded batch, preserving the currently displayed pipe state.
  if cache.complete():
    return
  let
    visiblePipes = capturePipes()
    started = getMonoTime()
  restorePipes(cache.pipes)
  defer:
    cache.pipes = capturePipes()
    restorePipes(visiblePipes)
  while cache.section <= ScrubSegments:
    let destination = cache.duration * int32(cache.section) div ScrubSegments
    if cache.builder.world.tick < destination:
      cache.builder.advance()
      updatePipegridState(cache.builder.world)
      cache.explored.observeExploration(cache.builder.world)
      cache.tracks.observeTracks(cache.builder.world)
    if cache.builder.world.tick == destination:
      if cache.points[^1].world.tick != destination:
        cache.points.add ScrubPoint(
          world: cache.builder.world,
          explored: cache.explored,
          tracks: cache.tracks,
          pipes: capturePipes()
        )
      inc cache.section
    if (getMonoTime() - started).inMilliseconds >= milliseconds:
      break

proc requiredTick*(cache: ScrubCache, target: int32, nearest = false): int32 =
  ## Finds the requested five-percent checkpoint even before it is indexed.
  let destination = clamp(target, 0'i32, cache.duration)
  for section in 0 .. ScrubSegments:
    let tick = cache.duration * int32(section) div ScrubSegments
    if nearest:
      if abs(tick - destination) < abs(result - destination):
        result = tick
    elif tick <= destination:
      result = tick

proc available*(cache: ScrubCache, target: int32, nearest = false): bool =
  ## Reports whether a seek can use its intended checkpoint immediately.
  cache.points.len > 0 and
    cache.points[^1].world.tick >= cache.requiredTick(target, nearest)

proc buildScrubs*(tape: Replay): ScrubCache =
  ## Builds the same bounded checkpoint index synchronously for tests.
  result = beginScrubs(tape)
  while not result.complete():
    result.extendScrubs(1000)

proc pointAt*(cache: ScrubCache, target: int32, nearest = false): int =
  ## Chooses a preceding exact-seek checkpoint or the nearest drag preview.
  assert cache.points.len > 0
  let destination = clamp(target, 0'i32, cache.duration)
  for i, point in cache.points:
    if nearest:
      if abs(point.world.tick - destination) <
        abs(cache.points[result].world.tick - destination):
          result = i
    elif point.world.tick <= destination:
      result = i
