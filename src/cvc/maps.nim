import
  std/algorithm,
  polyworld/rngs,
  common

proc addStation*(world: var World, station: Station) =
  ## Adds one station with a stable index and clears its access tiles.
  if world.stations.len >= MaxStations:
    fail("station capacity exceeded")
  if station.tile notin 0 ..< TileCount:
    fail("station tile is outside the map")
  if world.tiles[station.tile].station >= 0:
    fail("two stations occupy the same tile")
  world.tiles[station.tile].wall = false
  world.tiles[station.tile].station = int16(world.stations.len)
  world.stations.add station
  for direction in North .. West:
    let tile = station.tile.neighbor(direction)
    if tile >= 0:
      world.tiles[tile].wall = false

const Arena* = staticRead("../../data/maps/machina1.txt")

proc generate*(seed: int32): World =
  ## Loads the original fixed Machina-1 arena into flat simulation state.
  result.seed = seed
  result.rng = initRng(seed)
  var
    slot = 0
    stations: seq[Station]
  for tile in 0 ..< TileCount:
    result.tiles[tile].station = -1
    result.tiles[tile].wall = Arena[tile + tile div Width] == '#'
  for tile in 0 ..< TileCount:
    let symbol = Arena[tile + tile div Width]
    var station = Station(tile: int32(tile))
    case symbol
    of 'h':
      station.kind = Hub
      station.owner = Cogs
    of 'a', 'b', 'm', 's':
      station.kind = Gear
      station.owner = Cogs
      station.role = case symbol
        of 'a': Aligner
        of 'b': Scrambler
        of 'm': Miner
        else: Scout
    of '1' .. '4':
      station.kind = Ship
      station.owner = Clips
      station.lane = int8(ord(symbol) - ord('0'))
    of 'j':
      station.kind = Junction
    of 'C', 'O', 'G', 'S':
      station.kind = Extractor
      station.stock = 200
      station.element = case symbol
        of 'C': Carbon
        of 'O': Oxygen
        of 'G': Germanium
        else: Silicon
    of '@':
      result.cogs[slot] = Cog(tile: int32(tile), hp: 50,
        energy: 20, direction: South)
      inc slot
      continue
    else:
      continue
    stations.add(station)
  stations.sort(proc(a, b: Station): int =
    ## Keeps compound station identities stable across the fixed map port.
    let
      ranks = [0, 2, 3, 4, 1]
      rankA = ranks[ord(a.kind)]
      rankB = ranks[ord(b.kind)]
    result = cmp(rankA, rankB)
    if result == 0 and a.kind == Gear:
      result = cmp(ord(a.role), ord(b.role))
    if result == 0:
      result = cmp(a.tile, b.tile)
  )
  for station in stations:
    result.tiles[station.tile].station = int16(result.stations.len)
    result.stations.add(station)
  doAssert slot == CogCount
  for element in Element:
    result.bank[element] = CogCount * 3
  result.hearts = 5
