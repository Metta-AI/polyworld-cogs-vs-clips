import observations, sims

const TrainingAbi* = 1

type
  Lane = object
    world: World
    observer: Observer
  TrainingBatch = ref object
    lanes: seq[Lane]
    limit: int32
  TrainingStats* {.bycopy.} = object
    episodes*: int64
    ticks*: int64
    score*: int64
    gathered*, deposited*, captured*: int64

var lastError: string

proc cvc_error(): cstring {.cdecl, exportc, dynlib.} =
  ## Returns the most recent boundary failure on the calling thread.
  lastError.cstring

proc cvc_abi(): cint {.cdecl, exportc, dynlib.} =
  ## Identifies the fixed shared-buffer ABI.
  TrainingAbi

proc cvc_tokens(): cint {.cdecl, exportc, dynlib.} =
  ## Reports the token count without Python duplicating the allocation size.
  ObservationTokens

proc cvc_create(count, limit: cint): pointer {.cdecl, exportc, dynlib.} =
  ## Allocates independent synchronous matches on the caller's thread.
  if count notin 1 .. 128 or limit notin 1 .. MaxTicks:
    lastError = "match count or tick limit outside supported range"
    return nil
  let batch = TrainingBatch(lanes: newSeq[Lane](count), limit: limit)
  GC_ref(batch)
  cast[pointer](batch)

proc cvc_reset(handle: pointer, seed: int32,
    observations: ptr UncheckedArray[ObservationBatch]
): cint {.cdecl, exportc, dynlib.} =
  ## Resets all matches and fills caller-owned contiguous observation buffers.
  if handle == nil or observations == nil:
    lastError = "null reset handle or observations"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index in 0 ..< batch.lanes.len:
    batch.lanes[index].world = initWorld(seed +% int32(index))
    batch.lanes[index].observer.observe(batch.lanes[index].world,
      observations[index])

proc cvc_step(handle: pointer, choices: ptr UncheckedArray[int32],
    observations: ptr UncheckedArray[ObservationBatch],
    rewards: ptr UncheckedArray[float32],
    terminals: ptr UncheckedArray[uint8], stats: ptr TrainingStats
): cint {.cdecl, exportc, dynlib.} =
  ## Advances one lockstep tick and auto-resets completed matches.
  if handle == nil or choices == nil or observations == nil or
    rewards == nil or terminals == nil or stats == nil:
      lastError = "null step handle or output buffer"
      return -1
  let batch = cast[TrainingBatch](handle)
  # Validate the complete batch before mutating any match.
  for index in 0 ..< batch.lanes.len * CogCount:
    if choices[index] notin ord(Rest) .. ord(West):
      lastError = "action must be in 0 .. 4"
      return -1
  for index in 0 ..< batch.lanes.len:
    var actions: Actions
    for slot in 0 ..< CogCount:
      actions[slot] = Action(choices[index * CogCount + slot])
    let previous = batch.lanes[index].world.scores
    batch.lanes[index].world.tick(actions)
    inc stats.ticks
    let done = batch.lanes[index].world.tick >= batch.limit
    for slot, cog in batch.lanes[index].world.cogs:
      let offset = index * CogCount + slot
      terminals[offset] = uint8(done)
      rewards[offset] = float32(
        batch.lanes[index].world.scores[cog.team] - previous[cog.team]
      ) * 0.001'f
      # Training-only shaping; the simulation and match score are unchanged.
      case cog.feedback
      of Gathered:
        rewards[offset] += 0.01'f
        inc stats.gathered
      of Deposited:
        rewards[offset] += 0.02'f
        inc stats.deposited
      of Captured:
        rewards[offset] += 0.1'f
        inc stats.captured
      else:
        discard
    if done:
      inc stats.episodes
      for team in Teams:
        stats.score += batch.lanes[index].world.scores[team]
      let seed = batch.lanes[index].world.seed +% int32(batch.lanes.len)
      batch.lanes[index].world = initWorld(seed)
    batch.lanes[index].observer.observe(batch.lanes[index].world,
      observations[index])

proc cvc_hash(handle: pointer, index: cint): uint64
    {.cdecl, exportc, dynlib.} =
  ## Exposes deterministic state hashes for adapter verification.
  let batch = cast[TrainingBatch](handle)
  if handle != nil and index >= 0 and index < batch.lanes.len:
    result = batch.lanes[index].world.stateHash

proc cvc_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  ## Releases all native match storage on its owning thread.
  if handle != nil:
    GC_unref(cast[TrainingBatch](handle))
