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

const Arena* = staticRead("../../data/maps/fourscore.txt")

proc generate*(seed: int32): World =
  ## Loads the original fixed FourScore arena into flat simulation state.
  result.seed = seed
  result.rng = initRng(seed)
  var
    slots: array[TeamCount, int]
    stations: seq[Station]
  for tile in 0 ..< TileCount:
    result.tiles[tile].station = -1
    result.tiles[tile].wall = Arena[tile + tile div Width] == '#'
  for tile in 0 ..< TileCount:
    let symbol = Arena[tile + tile div Width]
    let team = Teams[(tile mod Width div (Width div 2)) +
      2 * (tile div Width div (Height div 2))]
    var station = Station(tile: int32(tile))
    case symbol
    of 'h':
      station.kind = Hub
      station.owner = team
    of 'a', 'b', 'm', 's':
      station.kind = Gear
      station.owner = team
      station.role = case symbol
        of 'a': Aligner
        of 'b': Scrambler
        of 'm': Miner
        else: Scout
    of 'j':
      station.kind = Junction
    of 'C', 'O', 'G', 'S':
      station.kind = Extractor
      station.stock = 100
      station.element = case symbol
        of 'C': Carbon
        of 'O': Oxygen
        of 'G': Germanium
        else: Silicon
    of '0' .. '3':
      let group = ord(symbol) - ord('0')
      let slot = group * TeamSize + slots[group]
      result.cogs[slot] = Cog(team: Teams[group], tile: int32(tile), hp: 50,
        energy: 20, direction: South)
      inc slots[group]
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
  for team in Teams:
    doAssert slots[ord(team) - 1] == TeamSize
    for element in Element:
      result.banks[team][element] = TeamSize * 3
    result.hearts[team] = 5
