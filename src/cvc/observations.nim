import common, sims

when defined(cvcObsTrace):
  import profiles
else:
  template measure(fn: untyped): untyped =
    ## Removes observation profiling from normal builds.
    fn

const
  ObservationVersion* = 1
  ObservationTokens* = 2048
  GlobalLocation* = 254'u8
  EmptyByte* = 255'u8
  ViewWidth* = 13

type
  Feature* = enum
    Kind, Team, Equipment, Identity, Health, Energy,
    CarbonAmount, OxygenAmount, GermaniumAmount, SiliconAmount,
    Hearts, Stock, Resource, Tick, LastAction, LastFeedback,
    BankCarbon, BankOxygen, BankGermanium, BankSilicon,
    BankHearts, Score, Territory
  Token* = array[3, uint8]
  Observation* = array[ObservationTokens, Token]
  ObservationBatch* = array[CogCount, Observation]
  Observer* = object
    occupants: array[TileCount, int16]
  Offset = object
    dx, dy: int32
    location: uint8

const Offsets = block:
  var
    offsets: array[ViewWidth * ViewWidth, Offset]
    index = 0
  for distance in 0 .. 12:
    for dy in -6 .. 6:
      for dx in -6 .. 6:
        if abs(dx) + abs(dy) == distance:
          offsets[index] = Offset(dx: dx.int32, dy: dy.int32,
            location: uint8(((dy + 6) shl 4) or (dx + 6)))
          inc index
  offsets

proc emit(obs: var Observation, count: var int, location: uint8,
    feature: Feature, value: int64) {.inline.} =
  ## Writes an unsigned base-256 integer with four reserved feature IDs.
  var
    remaining = uint64(clamp(value, 0'i64, int64(high(uint32))))
    power = 0
  while true:
    if count >= ObservationTokens:
      fail("observation token capacity exceeded")
    obs[count] = [location, uint8(ord(feature) * 4 + power),
      uint8(remaining and 255)]
    inc count
    remaining = remaining shr 8
    if remaining == 0:
      break
    inc power

proc prepare*(observer: var Observer, world: World) {.measure.} =
  ## Builds one flat occupancy index shared by all observers this tick.
  for tile in 0 ..< TileCount:
    observer.occupants[tile] = -1
  for slot, cog in world.cogs:
    observer.occupants[cog.tile] = int16(slot)

proc fillBytes(buffer: pointer, value: cint, size: csize_t): pointer
    {.importc: "memset", header: "<string.h>", discardable.}
  ## Fills a proven contiguous byte range using the platform primitive.

proc clearPadding(obs: var Observation, count: int) {.measure.} =
  ## Clears the unused suffix so previous ticks cannot leak stale tokens.
  if count < ObservationTokens:
    fillBytes(addr obs[count], 255,
      csize_t((ObservationTokens - count) * sizeof(Token)))

proc encode(world: World, slot: int, observer: Observer,
    obs: var Observation, reference: static bool): int {.measure.} =
  ## Encodes global values followed by nearest-first visible objects.
  let cog = world.cogs[slot]
  template add(location: uint8, feature: Feature, value: untyped) =
    emit(obs, result, location, feature, int64(value))
  add(GlobalLocation, Tick, world.tick)
  add(GlobalLocation, LastAction, ord(cog.direction))
  add(GlobalLocation, LastFeedback, ord(cog.feedback))
  add(GlobalLocation, Team, ord(cog.team))
  add(GlobalLocation, Score, world.scores[cog.team])
  add(GlobalLocation, BankHearts, world.hearts[cog.team])
  add(GlobalLocation, Territory, ord(world.territory(cog.tile)))
  for element in Element:
    add(GlobalLocation, Feature(ord(BankCarbon) + ord(element)),
      world.banks[cog.team][element])
  for offset in Offsets:
    let
      tile = tileAt(cog.tile.x + offset.dx, cog.tile.y + offset.dy)
      location = offset.location
    if tile < 0:
      continue
    var
      occupant = -1
      stationIndex = -1
    when reference:
      for index, other in world.cogs:
        if other.tile == tile:
          occupant = index
      for index, station in world.stations:
        if station.tile == tile and
          (station.kind != Extractor or station.stock > 0):
            stationIndex = index
    else:
      occupant = int(observer.occupants[tile])
      stationIndex = int(world.tiles[tile].station)
    if occupant >= 0:
      let other = world.cogs[occupant]
      add(location, Kind, 2)
      add(location, Team, ord(other.team))
      add(location, Equipment, ord(other.role))
      add(location, Identity, occupant)
      add(location, Health, other.hp)
      add(location, Energy, other.energy)
      add(location, Hearts, other.hearts)
      for element in Element:
        add(location, Feature(ord(CarbonAmount) + ord(element)),
          other.cargo[element])
    elif world.tiles[tile].wall:
      add(location, Kind, 1)
    elif stationIndex >= 0:
      let station = world.stations[stationIndex]
      add(location, Kind, 3 + ord(station.kind))
      add(location, Team, ord(station.owner))
      case station.kind
      of Extractor:
        add(location, Stock, station.stock)
        add(location, Resource, ord(station.element))
      of Gear:
        add(location, Equipment, ord(station.role))
      else:
        discard
  # Padding is observable and must never retain tokens from an older tick.
  clearPadding(obs, result)

proc observe*(observer: var Observer, world: World,
    output: var ObservationBatch) {.measure.} =
  ## Writes all fixed-schema observations without allocation or sim mutation.
  observer.prepare(world)
  for slot in 0 ..< CogCount:
    discard encode(world, slot, observer, output[slot], false)

proc observeOne*(observer: Observer, world: World, slot: int,
    output: var Observation) =
  ## Encodes one seat after the caller prepares the occupancy index.
  assert slot in 0 ..< CogCount
  discard encode(world, slot, observer, output, false)

proc observeReference*(world: World,
    output: var ObservationBatch) {.measure.} =
  ## Builds the same tokens using deliberately direct object lookup.
  var observer: Observer
  for slot in 0 ..< CogCount:
    discard encode(world, slot, observer, output[slot], true)
