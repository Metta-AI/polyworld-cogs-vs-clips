import
  cvc/[sims, bots, pipes]

proc snapshots(uncached: bool): seq[string] =
  ## Exercises live growth, obstacle changes, depletion, and resets.
  disablePipeCache = uncached
  resetPipegridState()
  var world = initWorld(1)
  let policies = newBots()
  for frame in 0 ..< 1120:
    if frame == 1100:
      world.tiles[tileAt(44, 43)].wall = true
      for station in world.stations.mitems:
        if station.kind == Extractor:
          station.stock = 0
        elif station.kind == Junction:
          station.owner = Red
    if frame == 1110:
      resetPipegridState()
    world.tick(policies.decide(world))
    updatePipegridState(world)
    result.add(pipeSnapshot())

let cached = snapshots(false)
let reference = snapshots(true)
doAssert cached == reference, "Cached pipes changed route geometry."
echo "1,120 cached/reference pipe states match."
