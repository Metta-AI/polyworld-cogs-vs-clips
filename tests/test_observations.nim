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
