import
  std/[os, strutils],
  cvc/[sims, replays, bots]

when not defined(headless):
  import cvc/clients

proc main() =
  ## Runs a headless match or launches the shared rich client.
  var
    seed = 1'i32
    recordPath = ""
    replayPath = ""
    policy = BaselineSource
    headless = false
    i = 1
  while i <= paramCount():
    let argument = paramStr(i)
    if argument == "--headless":
      headless = true
    elif argument in ["--seed", "--record", "--replay", "--bot"]:
      inc i
      if i > paramCount():
        fail("missing value for " & argument)
      let value = paramStr(i)
      case argument
      of "--seed":
        try:
          let parsed = parseBiggestInt(value)
          if parsed < int32.low or parsed > int32.high:
            fail("seed must fit a signed 32-bit integer")
          seed = int32(parsed)
        except ValueError:
          fail("seed must be an integer")
      of "--record": recordPath = value
      of "--replay": replayPath = value
      of "--bot":
        try:
          policy = readFile(value)
        except IOError as error:
          fail("cannot read policy: " & error.msg)
      else: discard
    elif argument == "--help":
      echo "cvc [--seed N] [--bot FILE] [--record FILE] [--replay FILE]"
      echo "    [--headless]"
      return
    else:
      fail("unknown argument: " & argument)
    inc i
  let session =
    if replayPath.len > 0: load(replayPath) else: newSession(seed)
  when defined(headless):
    headless = true
  if headless:
    let policies = if session.playback: nil else: newBots(policy)
    let duration =
      if session.playback: int32(session.tape.hashes.len) else: MaxTicks
    while session.world.tick < duration:
      if session.playback:
        session.advance()
      else:
        session.advance(policies.decide(session.world))
    echo "tick=", session.world.tick, " score=", session.world.score,
      " clips=", session.world.clipsScore, " hash=", session.world.stateHash
    if recordPath.len > 0:
      session.save(recordPath)
  else:
    when not defined(headless):
      runClient(session, policy, recordPath)

try:
  main()
except CvcError as error:
  echo "CVC: ", error.msg
  quit(1)
