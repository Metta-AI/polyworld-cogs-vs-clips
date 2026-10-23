import common

const TrackLifetime* = 200

type
  Track* = object
    tile*, tick*: int32
    incoming*, outgoing*: Action
  Tracks* = object
    marks*: array[CogCount, array[TrackLifetime, Track]]
    counts*: array[CogCount, int]
    heads: array[CogCount, int]
    previous: array[CogCount, int32]
    directions: array[CogCount, Action]
    initialized: bool
    tick: int32

proc observeTracks*(tracks: var Tracks, world: World) =
  ## Keeps bounded visual movement history without changing simulation state.
  if not tracks.initialized:
    tracks.initialized = true
    tracks.tick = world.tick
    for i, cog in world.cogs:
      tracks.previous[i] = cog.tile
      tracks.directions[i] = South
    return
  if world.tick <= tracks.tick:
    return
  tracks.tick = world.tick
  for i, cog in world.cogs:
    let previous = tracks.previous[i]
    tracks.previous[i] = cog.tile
    if previous == cog.tile:
      continue
    var direction = Rest
    for action in North .. West:
      if previous.neighbor(action) == cog.tile:
        direction = action
        break
    if direction == Rest:
      tracks.directions[i] = South
      continue
    let incoming = tracks.directions[i]
    tracks.directions[i] = direction
    if abs(ord(incoming) - ord(direction)) == 2:
      continue
    tracks.marks[i][tracks.heads[i]] = Track(
      tile: previous,
      tick: world.tick,
      incoming: incoming,
      outgoing: direction
    )
    tracks.heads[i] = (tracks.heads[i] + 1) mod TrackLifetime
    tracks.counts[i] = min(TrackLifetime, tracks.counts[i] + 1)

proc sprite*(track: Track): string =
  ## Selects the original straight or corner tire-track sprite.
  const Directions = ["", "n", "e", "s", "w"]
  "agents/tracks." & Directions[ord(track.incoming)] &
    Directions[ord(track.outgoing)]
