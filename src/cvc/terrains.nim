import
  common

const PatternToTile = [
  18, 17, 4, 4, 12, 22, 4, 4, 30, 13, 41, 41, 30, 13, 41, 41, 19, 23, 5, 5, 37,
  9, 5, 5, 30, 13, 41, 41, 30, 13, 41, 41, 24, 43, 39, 39, 44, 45, 39, 39, 48,
  32, 46, 46, 48, 32, 46, 46, 24, 43, 39, 39, 44, 45, 39, 39, 48, 32, 46, 46,
  48, 32, 46, 46, 36, 10, 3, 3, 16, 40, 3, 3, 20, 27, 6, 6, 20, 27, 6, 6, 25,
  15, 2, 2, 26, 38, 2, 2, 20, 27, 6, 6, 20, 27, 6, 6, 24, 43, 39, 39, 44, 45,
  39, 39, 48, 32, 46, 46, 48, 32, 46, 46, 24, 43, 39, 39, 44, 45, 39, 39, 48,
  32, 46, 46, 48, 32, 46, 46, 28, 28, 8, 8, 21, 21, 8, 8, 33, 33, 7, 7, 33, 33,
  7, 7, 35, 35, 31, 31, 14, 14, 31, 31, 33, 33, 7, 7, 33, 33, 7, 7, 47, 47, 1,
  1, 42, 42, 1, 1, 34, 34, 0, 0, 34, 34, 0, 0, 47, 47, 1, 1, 42, 42, 1, 1,
  34, 34, 0, 0, 34, 34, 0, 0, 28, 28, 8, 8, 21, 21, 8, 8, 33, 33, 7, 7, 33,
  33, 7, 7, 35, 35, 31, 31, 14, 14, 31, 31, 33, 33, 7, 7, 33, 33, 7, 7, 47, 47,
  1, 1, 42, 42, 1, 1, 34, 34, 0, 0, 34, 34, 0, 0, 47, 47, 1, 1, 42, 42, 1,
  1, 34, 34, 0, 0, 34, 34, 0, 0
]

type
  Terrain* = object
    edges*: array[TileCount, uint8]
    splats*: seq[tuple[tile: int32, variant: int]]

proc wall(world: World, x, y: int32): int =
  ## Treats positions beyond the map as the asteroid exterior.
  let tile = tileAt(x, y)
  if tile < 0 or world.tiles[tile].wall:
    return 1
  0

proc terrain*(world: World): Terrain =
  ## Derives presentation caches without consuming simulation randomness.
  for tile in 0'i32 ..< TileCount:
    let
      x = tile.x
      y = tile.y
    if world.tiles[tile].wall:
      result.edges[tile] = 49
    else:
      let pattern =
        world.wall(x - 1, y - 1) + 2 * world.wall(x, y - 1) +
        4 * world.wall(x + 1, y - 1) + 8 * world.wall(x + 1, y) +
        16 * world.wall(x + 1, y + 1) + 32 * world.wall(x, y + 1) +
        64 * world.wall(x - 1, y + 1) + 128 * world.wall(x - 1, y)
      let edge = PatternToTile[pattern]
      result.edges[tile] = uint8(if edge in [18, 29]: 50 else: edge)
    if x mod 5 == 2 and y mod 5 == 2 and not world.tiles[tile].wall:
      let value = uint32(tile) * 1664525'u32 xor cast[uint32](world.seed)
      result.splats.add((tile, int(value mod 8) + 1))

proc pipes*(world: World): seq[tuple[tile: int32, sprite: string, owner: Owner]] =
  ## Derives a bounded rooted pipe tree from current owned junctions.
  var reached: array[MaxStations, bool]
  for i, station in world.stations:
    reached[i] = station.kind in {Hub, Ship}
  var changed = true
  while changed:
    changed = false
    for i, station in world.stations:
      if reached[i] or station.kind != Junction or station.owner == Neutral:
        continue
      var
        parent = -1
        distance = HubAlignRadius * HubAlignRadius + 1
      for j, other in world.stations:
        let candidate = station.tile.distance2(other.tile)
        if reached[j] and other.owner == station.owner and candidate < distance:
          parent = j
          distance = candidate
      if parent < 0:
        continue
      reached[i] = true
      changed = true
      let target = world.stations[parent].tile
      var
        x = station.tile.x
        y = station.tile.y
      while x != target.x:
        x += (if x < target.x: 1'i32 else: -1'i32)
        let tile = tileAt(x, y)
        if not world.tiles[tile].wall:
          result.add((tile, "terrain/pipegrid.ee", station.owner))
      while y != target.y:
        y += (if y < target.y: 1'i32 else: -1'i32)
        let tile = tileAt(x, y)
        if not world.tiles[tile].wall:
          result.add((tile, "terrain/pipegrid.nn", station.owner))
