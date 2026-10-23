import
  std/os,
  cvc/[sims, tracks, replays, scrubs, bots]

var
  world = initWorld(1)
  history: Tracks
world.cogs[0].tile = tileAt(50, 50)
history.observeTracks(world)
let before = world.stateHash
history.observeTracks(world)
doAssert world.stateHash == before and history.counts[0] == 0
world.cogs[0].tile = world.cogs[0].tile.neighbor(East)
inc world.tick
history.observeTracks(world)
doAssert history.counts[0] == 1
doAssert history.marks[0][0].sprite == "agents/tracks.se"
world.cogs[0].tile = world.cogs[0].tile.neighbor(North)
inc world.tick
history.observeTracks(world)
doAssert history.marks[0][1].sprite == "agents/tracks.en"
inc world.tick
history.observeTracks(world)
doAssert history.counts[0] == 2
world.cogs[0].tile = world.cogs[0].tile.neighbor(South)
inc world.tick
history.observeTracks(world)
doAssert history.counts[0] == 2
for tick in 0 ..< 1000:
  world.cogs[0].tile = world.cogs[0].tile.neighbor(
    [East, South, West, North][tick mod 4]
  )
  inc world.tick
  history.observeTracks(world)
doAssert history.counts[0] == TrackLifetime
for mark in history.marks[0]:
  doAssert fileExists("data/" & mark.sprite & ".png")

echo "Straight/corner tracks, idle frames, reversals, and bounded history pass."

let
  live = newSession(1)
  policies = newBots()
var expected: Tracks
expected.observeTracks(live.world)
for tick in 0 ..< 300:
  live.advance(policies.decide(live.world))
  expected.observeTracks(live.world)
let cache = buildScrubs(live.tape)
doAssert cache.points[^1].tracks == expected
let replay = fromReplay(live.tape)
var sequential: Tracks
sequential.observeTracks(replay.world)
for point in cache.points:
  while replay.world.tick < point.world.tick:
    replay.advance()
    sequential.observeTracks(replay.world)
  doAssert point.tracks == sequential
let point = cache.points[cache.pointAt(237)]
replay.world = point.world
var restored = point.tracks
while replay.world.tick < 300:
  replay.advance()
  restored.observeTracks(replay.world)
doAssert restored == expected
doAssert point.tracks == cache.points[cache.pointAt(237)].tracks
echo "Snapshot restore and exact seek reproduce uninterrupted tire tracks."
