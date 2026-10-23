import
  polyworld/rngs,
  common

type YieldMemory* = object
  destinations: array[2, int32]
  count: int

proc yieldMove*(
  memory: var YieldMemory,
  world: World,
  slot: int,
  proposed: Action,
  crowded: bool
): Action =
  ## Breaks repeated movement with a per-seat deterministic fifty-percent wait.
  result = proposed
  let destination = world.cogs[slot].tile.neighbor(proposed)
  var repeated = false
  for i in 0 ..< memory.count:
    repeated = repeated or memory.destinations[i] == destination
  memory.destinations[1] = memory.destinations[0]
  memory.destinations[0] =
    if proposed == Rest:
      -1
    else:
      destination
  memory.count = min(2, memory.count + 1)
  if proposed == Rest or destination < 0 or
    world.tiles[destination].station >= 0 or not (crowded or repeated):
      return
  var coin = initRng(
    world.seed,
    (uint64(cast[uint32](world.tick)) shl 32) or uint64(slot + 1)
  )
  if coin.below(2) == 0:
    result = Rest
