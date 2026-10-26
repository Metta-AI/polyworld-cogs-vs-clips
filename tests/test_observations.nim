import cvc/[sims, observations]

var
  world = initWorld(1)
  observer: Observer
  fast, reference: ObservationBatch
  actions: Actions
for tick in 0 ..< 100:
  for slot in 0 ..< CogCount:
    actions[slot] = Action((tick + slot) mod 5)
  world.tick(actions)
  let hash = world.stateHash
  observer.observe(world, fast)
  world.observeReference(reference)
  doAssert fast == reference
  doAssert world.stateHash == hash
  doAssert fast[0][0] == [GlobalLocation, uint8(ord(Tick) * 4),
    uint8(world.tick)]
# Force edge windows, high inventory values and disappearing entities.
world.cogs[0].tile = 0
world.cogs[0].hp = 500
world.cogs[0].cargo[Carbon] = 65535
world.scores[Red] = 1_000_000
for index in 0 ..< world.stations.len:
  if world.stations[index].kind == Extractor:
    world.stations[index].stock = 0
    world.tiles[world.stations[index].tile].station = -1
observer.observe(world, fast)
world.observeReference(reference)
doAssert fast == reference
var highHp = false
for token in fast[0]:
  if token[0] == 0x66 and token[1] == uint8(ord(Health) * 4 + 1):
    highHp = token[2] == 1
doAssert highHp
# Outside the local window cannot leak an enemy inventory.
let before = fast[0]
world.cogs[31].cargo[Carbon] += 123
observer.observe(world, fast)
doAssert fast[0] == before
echo "Observation reference, boundaries, padding and visibility pass."

proc number(obs: Observation, location: uint8, feature: Feature): uint64 =
  ## Independently decodes the reserved little-endian feature bytes.
  for token in obs:
    let power = int(token[1]) - ord(feature) * 4
    if token[0] == location and power in 0 .. 3:
      result = result or (uint64(token[2]) shl (power * 8))

doAssert fast[0].number(0x66, Health) == 500
doAssert fast[0].number(0x66, CarbonAmount) == 65535
doAssert fast[0].number(GlobalLocation, Score) == 1_000_000
var padding = false
for token in fast[0]:
  if token[0] == EmptyByte:
    padding = true
    doAssert token == [EmptyByte, EmptyByte, EmptyByte]
  else:
    doAssert not padding
    doAssert token[0] == GlobalLocation or
      (token[0] shr 4 <= 12 and (token[0] and 15) <= 12)

# Crowded windows exercise all 32 dynamic objects and multi-byte inventories.
world.stations.setLen(0)
for tile in 0 ..< TileCount:
  world.tiles[tile].wall = false
  world.tiles[tile].station = -1
for slot in 0 ..< CogCount:
  world.cogs[slot].tile = tileAt(int32(60 + slot mod 7),
    int32(60 + slot div 7))
  world.cogs[slot].role = Scout
  world.cogs[slot].hp = 500
  for element in Element:
    world.cogs[slot].cargo[element] = 65535
observer.observe(world, fast)
world.observeReference(reference)
doAssert fast == reference
var identities = 0
for token in fast[0]:
  if token[0] != EmptyByte and token[1] == uint8(ord(Identity) * 4):
    inc identities
doAssert identities == CogCount
echo "Large values decode exactly and crowded windows retain every cog."
