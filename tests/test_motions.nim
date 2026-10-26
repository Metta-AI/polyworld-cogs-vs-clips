import
  vmath,
  cvc/[sims, motions]

var
  world = initWorld(1)
  motion: Motion
motion.reset(world)
let start = world.cogs[0].tile
world.cogs[0].direction = East
world.cogs[0].tile = start.neighbor(East)
inc world.tick
motion.observe(world)
doAssert motion.position(0, 0, 1) == vec2(start.x.float32, start.y.float32)
doAssert motion.position(0, 1, 1) ==
  vec2(world.cogs[0].tile.x.float32, world.cogs[0].tile.y.float32)
world.cogs[0].direction = North
world.cogs[0].feedback = Gathered
inc world.tick
motion.observe(world)
doAssert motion.direction(0, 0.1, 1) == "ne"
doAssert motion.position(0, 0.175, 1).y < world.cogs[0].tile.y.float32
doAssert motion.position(0, 1, 1).y == world.cogs[0].tile.y.float32
motion.reset(world)
doAssert motion.previous == world.cogs
echo "Causal animation endpoints, turns, bumps and resets pass."
