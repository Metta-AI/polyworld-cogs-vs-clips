include ../src/cvc/training

var
  output: ObservationBatch
  rewards: array[CogCount, float32]
  terminals: array[CogCount, uint8]
  choices: array[CogCount, int32]
  stats: TrainingStats
  events: array[CogCount, array[10, float32]]
let
  handle = cvc_create(1, 1)
  batch = cast[TrainingBatch](handle)
doAssert cvc_reset(handle, 42,
  cast[ptr UncheckedArray[ObservationBatch]](addr output)) == 0
# Put a miner next to a stocked extractor and remove movement conflicts.
var extractor = -1
for index, station in batch.lanes[0].world.stations:
  if station.kind == Extractor:
    let tile = station.tile.neighbor(South)
    if tile >= 0 and not batch.lanes[0].world.tiles[tile].wall and
      batch.lanes[0].world.tiles[tile].station < 0:
        extractor = index
        break
doAssert extractor >= 0
let station = batch.lanes[0].world.stations[extractor]
for slot in 1 ..< CogCount:
  batch.lanes[0].world.cogs[slot].tile = Hubs[3].int32
batch.lanes[0].world.cogs[0].tile = station.tile.neighbor(South)
batch.lanes[0].world.cogs[0].role = Miner
batch.lanes[0].world.cogs[0].hp = 100
batch.lanes[0].world.cogs[0].energy = 20
# A separate cog loses gear and hearts through health depletion.
batch.lanes[0].world.cogs[1].tile = 0
batch.lanes[0].world.cogs[1].hp = 1
batch.lanes[0].world.cogs[1].role = Aligner
batch.lanes[0].world.cogs[1].hearts = 2
choices[0] = int32(ord(North))
doAssert cvc_step(handle,
  cast[ptr UncheckedArray[int32]](addr choices),
  cast[ptr UncheckedArray[ObservationBatch]](addr output),
  cast[ptr UncheckedArray[float32]](addr rewards),
  cast[ptr UncheckedArray[uint8]](addr terminals), addr stats) == 0
doAssert cvc_safa_events(handle,
  cast[ptr UncheckedArray[array[10, float32]]](addr events)) == 0
doAssert terminals[0] == 1
doAssert events[0][3 + ord(station.element)] == 10
# Events belong to the terminal world, not the auto-reset world.
doAssert events[1][1] == -1
doAssert events[1][9] == 2
doAssert batch.lanes[0].world.tick == 0
cvc_close(handle)
echo "Safa event deltas and terminal preservation pass."
