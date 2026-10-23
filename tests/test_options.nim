import cvc/[options, bots, sims]

proc rejects(arguments: seq[string]) =
  ## Requires malformed command lines to use the game's error boundary.
  var rejected = false
  try:
    discard parseOptions(arguments)
  except CvcError:
    rejected = true
  doAssert rejected

for arguments in [
  @["--bots:players/base.bas:32", "--seed:-12", "--record:match.replay"],
  @["--bots", "players/base.bas:32", "--seed", "-12",
    "--record", "match.replay"],
  @["--bot=players/base.bas:32", "--seed=-12", "--record=match.replay"]
]:
  let settings = parseOptions(arguments)
  doAssert settings.seed == -12
  doAssert settings.recordPath == "match.replay"
  for source in settings.sources(BaselineSource):
    doAssert source == BaselineSource

let playback = parseOptions(@[
  "--replay:match.replay", "--play=false", "--speed", "5"
])
doAssert playback.replayPath == "match.replay"
doAssert playback.paused and playback.speed == 5
let mixed = parseOptions(@[
  "--bot:players/base.bas:16", "--bots:players/base.bas:16"
])
doAssert mixed.groups.len == 2
for arguments in [
  @["--bots:players/base.bas:7"],
  @["--replay:x", "--bots:players/base.bas:32"],
  @["--replay"], @["--record="], @["--speed:0"],
  @["--play:maybe"], @["--seed:999999999999"], @["--unknown"]
]:
  rejects(arguments)

var sources: array[CogCount, string]
for i in 0 ..< CogCount:
  sources[i] = "act(" & $(i mod 5) & ")"
let policies = newBots(sources)
var world = initWorld(1)
let actions = policies.decide(world)
for i, action in actions:
  doAssert ord(action) == i mod 5

echo "CLI syntax, bot groups, and per-slot policies passed."
