include ../src/cvc/training

var
  output: array[2, ObservationBatch]
  rewards: array[CogCount * 2, float32]
  terminals: array[CogCount * 2, uint8]
  choices: array[CogCount * 2, int32]
  stats: TrainingStats
  world = initWorld(7)
  observer: Observer
  expected: ObservationBatch
  actions: Actions
let handle = cvc_create(2, 100)
doAssert handle != nil
doAssert cvc_reset(handle, 7,
  cast[ptr UncheckedArray[ObservationBatch]](addr output)) == 0
for tick in 0 ..< 100:
  for slot in 0 ..< CogCount:
    actions[slot] = Action((slot + tick) mod 5)
    choices[slot] = int32(ord(actions[slot]))
    choices[CogCount + slot] = choices[slot]
  world.tick(actions)
  doAssert cvc_step(handle,
    cast[ptr UncheckedArray[int32]](addr choices),
    cast[ptr UncheckedArray[ObservationBatch]](addr output),
    cast[ptr UncheckedArray[float32]](addr rewards),
    cast[ptr UncheckedArray[uint8]](addr terminals), addr stats) == 0
  if tick == 99:
    world = initWorld(9)
  doAssert cvc_hash(handle, 0) == world.stateHash
  observer.observe(world, expected)
  doAssert output[0] == expected
  for terminal in terminals:
    doAssert terminal == uint8(tick == 99)
doAssert stats.episodes == 2
doAssert stats.ticks == 200
let before = cvc_hash(handle, 0)
choices[^1] = 5
doAssert cvc_step(handle,
  cast[ptr UncheckedArray[int32]](addr choices),
  cast[ptr UncheckedArray[ObservationBatch]](addr output),
  cast[ptr UncheckedArray[float32]](addr rewards),
  cast[ptr UncheckedArray[uint8]](addr terminals), addr stats) == -1
doAssert cvc_hash(handle, 0) == before
cvc_close(handle)
doAssert cvc_create(0, 100) == nil
echo "Native training matches direct simulation and resets atomically."
