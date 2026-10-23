import polyworld/rngs

const
  Width* = 120
  Height* = 120
  TileCount* = Width * Height
  TeamCount* = 4
  TeamSize* = 8
  CogCount* = TeamCount * TeamSize
  MaxTicks* = 10_000'i32
  MaxStations* = 800
  TickRate* = 20
  HeartCost* = 7'i32
  HeartLimit* = 10'i32
  CargoLimit* = 4'i32
  MinerCargo* = 44'i32
  MoveCost* = 4'i32
  DayLength* = 200'i32
  TerritoryRadius* = 10'i32
  HubRadius* = 20'i32
  AlignRadius* = 15'i32
  HubAlignRadius* = 25'i32
  ViewRadius* = 6'i32
  GameVersion* = 3'u16

type
  CvcError* = object of CatchableError
  Element* = enum
    Carbon, Oxygen, Germanium, Silicon
  Role* = enum
    Ungeared, Miner, Aligner, Scrambler, Scout
  Owner* = enum
    Neutral, Red, Blue, Green, Gold
  Action* = enum
    Rest, North, East, South, West
  StationKind* = enum
    Hub, Junction, Ship, Extractor, Gear
  Feedback* = enum
    Idle, Moved, Blocked, Gathered, Deposited, Equipped, Crafted,
    Captured, Disrupted, Exhausted, Broken
  Tile* = object
    wall*: bool
    biome*: uint8
    station*: int16
  Station* = object
    kind*: StationKind
    tile*: int32
    owner*: Owner
    element*: Element
    role*: Role
    stock*: int32
    lane*: int8
  Cog* = object
    team*: Owner
    tile*: int32
    direction*: Action
    role*: Role
    hp*: int32
    energy*: int32
    cargo*: array[Element, int32]
    hearts*: int32
    feedback*: Feedback
  World* = object
    seed*: int32
    tick*: int32
    rng*: Rng
    tiles*: array[TileCount, Tile]
    stations*: seq[Station]
    cogs*: array[CogCount, Cog]
    banks*: array[Owner, array[Element, int32]]
    hearts*: array[Owner, int32]
    scores*: array[Owner, int64]
  Actions* = array[CogCount, Action]

const
  Teams* = [Red, Blue, Green, Gold]
  Hubs* = [29 + 29 * Width, 89 + 29 * Width,
    29 + 89 * Width, 89 + 89 * Width]
  GearCosts*: array[Role, array[Element, int32]] = [
    [0'i32, 0, 0, 0], [1'i32, 1, 3, 1], [3'i32, 1, 1, 1],
    [1'i32, 3, 1, 1], [1'i32, 1, 1, 3]
  ]

proc fail*(message: string) {.noreturn.} =
  ## Raises a game-specific boundary error.
  raise newException(CvcError, message)

proc tileAt*(x, y: int32): int32 =
  ## Returns a tile index or minus one outside the map.
  if x < 0 or y < 0 or x >= Width or y >= Height:
    return -1
  y * Width + x

proc x*(tile: int32): int32 =
  ## Returns the tile column.
  tile mod Width

proc y*(tile: int32): int32 =
  ## Returns the tile row.
  tile div Width

proc distance2*(a, b: int32): int32 =
  ## Returns squared Euclidean distance without floating point.
  let
    dx = a.x - b.x
    dy = a.y - b.y
  dx * dx + dy * dy

proc neighbor*(tile: int32, action: Action): int32 =
  ## Returns the cardinal neighbor or the current tile for rest.
  case action
  of Rest: tile
  of North: tileAt(tile.x, tile.y - 1)
  of East: tileAt(tile.x + 1, tile.y)
  of South: tileAt(tile.x, tile.y + 1)
  of West: tileAt(tile.x - 1, tile.y)

proc maxHp*(role: Role): int32 =
  ## Returns the fixed health capacity for equipped gear.
  case role
  of Scrambler: 300
  of Scout: 500
  else: 100

proc maxEnergy*(role: Role): int32 =
  ## Returns the fixed energy capacity for equipped gear.
  if role == Scout: 120 else: 20

proc capacity*(role: Role): int32 =
  ## Returns the combined element carrying capacity.
  if role == Miner: MinerCargo else: CargoLimit

proc carried*(cog: Cog): int32 =
  ## Counts the elements in a Cog's inventory.
  for amount in cog.cargo:
    result += amount

proc visible*(world: World, slot: int, tile: int32): bool =
  ## Applies the fixed thirteen-by-thirteen observation window.
  slot in 0 ..< CogCount and tile in 0 ..< TileCount and
    abs(world.cogs[slot].tile.x - tile.x) <= ViewRadius and
    abs(world.cogs[slot].tile.y - tile.y) <= ViewRadius

proc home*(team: Owner): int32 =
  ## Returns the fixed corner hub for a playable team.
  if team == Neutral:
    return -1
  int32(Hubs[ord(team) - 1])
