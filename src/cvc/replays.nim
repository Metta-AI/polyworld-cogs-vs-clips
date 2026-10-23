import
  polyworld/[tapes, hashes],
  sims, profiles

const
  ReplayGame* = "four_score"
  TapeVersion* = 1'u16
  ContentHash* = uint64(hashy(
    staticRead("common.nim") & staticRead("maps.nim") & staticRead("../../data/maps/fourscore.txt") & staticRead("sims.nim")
  ))
  CheckpointPeriod* = 500

type
  Setup* = object
    seed*: int32
    maximumTicks*: uint32
    mapHash*: uint64
    contentHash*: uint64
  Frame* = object
    tick*: uint32
    actions*: Actions
  Replay* = ActionTape[Setup, Frame]
  Checkpoint* = object
    world*: World
  Session* = ref object
    world*: World
    tape*: Replay
    playback*: bool
    checkpoints*: seq[Checkpoint]
    error*: string

proc newSession*(seed: int32): Session =
  ## Starts a live match and its bounded action tape.
  new result
  result.world = initWorld(seed)
  result.tape = initActionTape[Setup, Frame](
    Setup(
      seed: seed,
      maximumTicks: uint32(MaxTicks),
      mapHash: result.world.stateHash,
      contentHash: ContentHash
    ),
    TapeVersion,
    GameVersion
  )
  result.tape.config = GameConfig(
    seed: seed,
    maxTicks: MaxTicks,
    players: unnamedPlayers(CogCount)
  )
  result.checkpoints.add Checkpoint(world: result.world)

proc validate*(tape: Replay) =
  ## Rejects incompatible setup and malformed action frames before playback.
  if tape.header.formatVersion != TapeVersion or
    tape.header.gameVersion != GameVersion:
      fail("unsupported CVC replay version")
  if tape.header.setup.maximumTicks != uint32(MaxTicks) or
    tape.header.setup.contentHash != ContentHash:
      fail("replay rules do not match this client")
  if tape.hashes.len > int(MaxTicks) or
    tape.actions.len != tape.hashes.len:
      fail("replay must contain one action frame and hash per tick")
  if tape.config.seed != tape.header.setup.seed or
    tape.config.maxTicks != MaxTicks or tape.config.players.len != CogCount:
      fail("replay match setup is inconsistent")
  for i, frame in tape.actions:
    if frame.tick != uint32(i + 1):
      fail("replay action ticks must be contiguous")
    for action in frame.actions:
      if ord(action) < ord(low(Action)) or ord(action) > ord(high(Action)):
        fail("replay contains an invalid action")
  if initWorld(tape.header.setup.seed).stateHash != tape.header.setup.mapHash:
    fail("replay map fingerprint does not match")

proc fromReplay*(tape: Replay): Session =
  ## Creates read-only playback after complete structural validation.
  tape.validate()
  result = newSession(tape.header.setup.seed)
  result.tape = tape
  result.playback = true

proc advance*(session: Session, actions: Actions = default(Actions)) {.measure.} =
  ## Advances live actions or recorded actions and checks the resulting hash.
  if session.error.len > 0 or session.world.tick >= MaxTicks:
    return
  let index = int(session.world.tick)
  if session.playback:
    if index >= session.tape.actions.len:
      return
    session.world.tick(session.tape.actions[index].actions)
    if session.world.stateHash != session.tape.hashes[index]:
      session.error = "replay diverged at tick " & $session.world.tick
      fail(session.error)
  else:
    session.world.tick(actions)
    session.tape.actions.appendAction(
      Frame(tick: uint32(session.world.tick), actions: actions), int(MaxTicks)
    )
    session.tape.hashes.appendHash(
      session.world.stateHash, uint32(MaxTicks), int(MaxTicks)
    )
  if session.world.tick mod CheckpointPeriod == 0 and
    session.checkpoints.len < int(MaxTicks) div CheckpointPeriod + 1:
      if session.world.tick > session.checkpoints[^1].world.tick:
        session.checkpoints.add Checkpoint(world: session.world)

proc seek*(session: Session, target: int32) =
  ## Restores the nearest cached checkpoint and verifies forward playback.
  if not session.playback:
    fail("seeking requires read-only playback")
  let destination = clamp(target, 0'i32, int32(session.tape.hashes.len))
  var best = 0
  for i, checkpoint in session.checkpoints:
    if checkpoint.world.tick <= destination and
      checkpoint.world.tick > session.checkpoints[best].world.tick:
        best = i
  session.world = session.checkpoints[best].world
  session.error = ""
  while session.world.tick < destination:
    session.advance()

proc replayBytes*(session: Session): string =
  ## Encodes a portable Poly World replay envelope.
  encodeReplayFile(ReplayGame, GameVersion, session.tape)

proc loadBytes*(bytes: string): Session =
  ## Decodes replay bytes and maps boundary errors to CvcError.
  try:
    let tape = decodeReplayFile(ReplayGame, GameVersion, bytes, Replay)
    result = fromReplay(tape)
  except CatchableError as error:
    fail("cannot load replay: " & error.msg)

proc save*(session: Session, path: string) =
  ## Saves the bounded action tape to disk.
  try:
    writeFile(path, session.replayBytes())
  except IOError as error:
    fail("cannot save replay: " & error.msg)

proc load*(path: string): Session =
  ## Loads and validates a saved action tape.
  try:
    result = loadBytes(readFile(path))
  except IOError as error:
    fail("cannot read replay: " & error.msg)
