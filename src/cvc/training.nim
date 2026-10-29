import observations, sims, neuralviews, bots

const TrainingAbi* = 1

type
  Lane = object
    world: World
    observer: Observer
    neural: NeuralView
    baseline: Bots
    scores: array[Owner, int64]
    events: array[CogCount, array[10, float32]]
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
    batch.lanes[index].neural = default(NeuralView)
    batch.lanes[index].baseline = nil
    reset(batch.lanes[index].scores)
    reset(batch.lanes[index].events)
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
    let
      previous = batch.lanes[index].world.scores
      before = batch.lanes[index].world.cogs
    batch.lanes[index].world.tick(actions)
    batch.lanes[index].neural.last = actions
    batch.lanes[index].scores = batch.lanes[index].world.scores
    inc stats.ticks
    let done = batch.lanes[index].world.tick >= batch.limit
    for slot, cog in batch.lanes[index].world.cogs:
      let offset = index * CogCount + slot
      # Training-only deltas survive terminal auto-reset.
      var events: array[10, float32]
      for gear in Miner .. Scrambler:
        events[ord(gear) - 1] = float32(
          int(cog.role == gear) - int(before[slot].role == gear)
        )
      for element in Element:
        events[3 + ord(element)] = float32(
          max(0, cog.cargo[element] - before[slot].cargo[element])
        )
      events[7] = float32(int(cog.feedback == Captured))
      events[8] = float32(int(cog.feedback == Disrupted))
      events[9] = float32(max(0, before[slot].hearts - cog.hearts))
      batch.lanes[index].events[slot] = events
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
      batch.lanes[index].neural = default(NeuralView)
      batch.lanes[index].baseline = nil
    batch.lanes[index].observer.observe(batch.lanes[index].world,
      observations[index])

proc cvc_hash(handle: pointer, index: cint): uint64
    {.cdecl, exportc, dynlib.} =
  ## Exposes deterministic state hashes for adapter verification.
  let batch = cast[TrainingBatch](handle)
  if handle != nil and index >= 0 and index < batch.lanes.len:
    result = batch.lanes[index].world.stateHash

proc cvc_safa_grid(handle: pointer, role: cint,
    output: ptr UncheckedArray[NeuralGrid]): cint
    {.cdecl, exportc, dynlib.} =
  ## Exposes the source-derived neural grid without changing simulation state.
  if handle == nil or output == nil or role notin 0 .. 10:
    lastError = "invalid Safa grid request"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index in 0 ..< batch.lanes.len:
    for slot in 0 ..< CogCount:
      batch.lanes[index].neural.neuralGrid(
        batch.lanes[index].world, slot, int(role),
        output[index * CogCount + slot]
      )

proc cvc_safa_events(handle: pointer,
    output: ptr UncheckedArray[array[10, float32]]): cint
    {.cdecl, exportc, dynlib.} =
  ## Copies gear, resource, junction, and heart deltas from the last tick.
  if handle == nil or output == nil:
    lastError = "invalid Safa event request"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index, lane in batch.lanes:
    for slot in 0 ..< CogCount:
      output[index * CogCount + slot] = lane.events[slot]

proc cvc_safa_observe(handle: pointer,
    roles: ptr UncheckedArray[array[CogCount, int32]],
    output: ptr UncheckedArray[NeuralGrid]): cint
    {.cdecl, exportc, dynlib.} =
  ## Builds per-seat observations using the actual sampled training roles.
  if handle == nil or roles == nil or output == nil:
    lastError = "invalid Safa observation request"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index in 0 ..< batch.lanes.len:
    for role in roles[index]:
      if role notin 0 .. 9:
        lastError = "Safa role must be in 0 .. 9"
        return -1
  for index in 0 ..< batch.lanes.len:
    for slot in 0 ..< CogCount:
      batch.lanes[index].neural.neuralGrid(
        batch.lanes[index].world, slot, int(roles[index][slot]),
        output[index * CogCount + slot], addr roles[index]
      )

proc cvc_baseline(handle: pointer, output: ptr UncheckedArray[int32]): cint
    {.cdecl, exportc, dynlib.} =
  ## Queries the existing baseline for controlled neural-policy comparisons.
  if handle == nil or output == nil:
    lastError = "invalid baseline request"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index in 0 ..< batch.lanes.len:
    if batch.lanes[index].baseline == nil:
      batch.lanes[index].baseline = newBots()
    let actions = batch.lanes[index].baseline.decide(batch.lanes[index].world)
    for slot in 0 ..< CogCount:
      output[index * CogCount + slot] = int32(actions[slot])

proc cvc_scores(handle: pointer, output: ptr UncheckedArray[int64]): cint
    {.cdecl, exportc, dynlib.} =
  ## Returns per-team scores from the last step, including terminal scores.
  if handle == nil or output == nil:
    lastError = "invalid score request"
    return -1
  let batch = cast[TrainingBatch](handle)
  for index in 0 ..< batch.lanes.len:
    for team, owner in Teams:
      output[index * TeamCount + team] = batch.lanes[index].scores[owner]

proc cvc_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  ## Releases all native match storage on its owning thread.
  if handle != nil:
    GC_unref(cast[TrainingBatch](handle))
