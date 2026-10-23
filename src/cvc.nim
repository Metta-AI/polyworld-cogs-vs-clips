import
  std/os,
  cvc/[sims, replays, bots, options, profiles]

when not defined(headless):
  import cvc/clients

proc main() =
  ## Runs a headless match or launches the shared rich client.
  let settings = parseOptions(commandLineParams())
  if settings.help:
    echo "cvc [--bots:FILE:COUNT ...] [--seed:N] [--record:FILE]"
    echo "    [--replay:FILE] [--play:true|false] [--speed:N] [--headless]"
    echo "--bot is an alias for --bots. Bot counts must total 32."
    echo "Values also accept --flag VALUE and --flag=VALUE."
    return
  let
    recordPath = settings.recordPath
    replayPath = settings.replayPath
    seed = settings.seed
    sources = settings.sources(BaselineSource)
  var headless = settings.headless
  let session =
    if replayPath.len > 0: load(replayPath) else: newSession(seed)
  when defined(headless):
    headless = true
  if headless:
    let policies = if session.playback: nil else: newBots(sources)
    let duration =
      if session.playback: int32(session.tape.hashes.len) else: MaxTicks
    when CvcTracePath.len > 0:
      defer:
        finishCapture(CvcTracePath)
    while session.world.tick < duration:
      when CvcTracePath.len > 0:
        if session.world.tick == CvcTraceWarmup:
          startCapture()
      if session.playback:
        session.advance()
      else:
        session.advance(policies.decide(session.world))
      when CvcTracePath.len > 0:
        if session.world.tick == CvcTraceWarmup + CvcTraceFrames:
          finishCapture(CvcTracePath)
    var scores: array[TeamCount, int64]
    for i, team in Teams:
      scores[i] = session.world.scores[team]
    echo "tick=", session.world.tick, " scores=", scores,
      " hash=", session.world.stateHash
    if recordPath.len > 0:
      session.save(recordPath)
  else:
    when not defined(headless):
      runClient(session, sources, recordPath, settings.paused, settings.speed)

try:
  main()
except CvcError as error:
  echo "CVC: ", error.msg
  quit(1)
