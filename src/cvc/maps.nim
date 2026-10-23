import
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

proc generate*(seed: int32): World =
  ## Builds the fixed-size seeded arena, compound, and corner ships.
  result.seed = seed
  result.rng = initRng(seed)
  for i in 0 ..< TileCount:
    result.tiles[i].station = -1
    let
      x = int32(i mod Width)
      y = int32(i div Width)
    result.tiles[i].wall = x == 0 or y == 0 or
      x == Width - 1 or y == Height - 1
    result.tiles[i].biome = uint8((x div 22 + y div 22) mod 4)
  result.addStation(Station(
    kind: Hub, tile: tileAt(44, 44), owner: Cogs
  ))
  for i, role in [Miner, Aligner, Scrambler, Scout]:
    let locations = [tileAt(37, 44), tileAt(44, 37),
      tileAt(51, 44), tileAt(44, 51)]
    result.addStation(Station(
      kind: Gear, tile: locations[i], owner: Cogs, role: role
    ))
  for i, tile in [tileAt(2, 2), tileAt(85, 2),
    tileAt(2, 85), tileAt(85, 85)]:
      result.addStation(Station(
        kind: Ship, tile: tile, owner: Clips, lane: int8(i + 1)
      ))
  for row in 0 ..< 9:
    for column in 0 ..< 9:
      let
        x = int32(7 + column * 9) + result.rng.between(-2, 2)
        y = int32(7 + row * 9) + result.rng.between(-2, 2)
        tile = tileAt(x, y)
      if tile.distance2(tileAt(44, 44)) < 81:
        continue
      result.addStation(Station(kind: Junction, tile: tile))
  for element in Element:
    for i in 0 ..< 66:
      for attempt in 0 ..< 200:
        let tile = tileAt(
          result.rng.between(3, Width - 4),
          result.rng.between(3, Height - 4)
        )
        if result.tiles[tile].station >= 0 or
          tile.distance2(tileAt(44, 44)) < 100:
            continue
        var clear = true
        for direction in North .. West:
          if result.tiles[tile.neighbor(direction)].station >= 0:
            clear = false
        if clear:
          result.addStation(Station(
            kind: Extractor, tile: tile, element: element, stock: 200
          ))
          break
  for element in Element:
    result.bank[element] = CogCount * 3
  result.hearts = 5
  for i in 0 ..< CogCount:
    result.cogs[i] = Cog(
      tile: tileAt(40 + int32(i), 46),
      hp: 50,
      energy: 20,
      direction: South
    )
