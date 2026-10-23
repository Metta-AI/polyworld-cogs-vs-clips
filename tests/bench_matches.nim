import
  benchy,
  cvc/sims

var checksum: uint64

timeIt "10,000 simulation ticks":
  var world = initWorld(1)
  for i in 0 ..< MaxTicks:
    world.tick(default(Actions))
  checksum = world.stateHash
  keep(checksum)
