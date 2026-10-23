import
  std/strutils,
  cvc/[sims, replays, bots]

proc signatures() =
  ## Writes every tick hash for cross-platform replay conformance.
  when defined(emscripten):
    let nativeReplay = load("native.replay")
    while nativeReplay.world.tick < int32(nativeReplay.tape.hashes.len):
      nativeReplay.advance()
  for seed in [1'i32, 42, -1]:
    let
      session = newSession(seed)
      policies = newBots()
    var lines = ""
    for tick in 0 ..< MaxTicks:
      session.advance(policies.decide(session.world))
      lines.add $seed & "," & $session.world.tick & "," &
        $session.world.stateHash & "\n"
    when defined(emscripten):
      echo lines.strip()
    else:
      writeFile("out/signatures-" & $seed & ".csv", lines)
    let playback = loadBytes(session.replayBytes())
    while playback.world.tick < MaxTicks:
      playback.advance()
    doAssert playback.world.stateHash == session.world.stateHash
    when not defined(emscripten):
      session.save("out/seed-" & $seed & ".replay")

signatures()
