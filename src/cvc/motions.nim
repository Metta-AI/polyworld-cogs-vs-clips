import
  std/math,
  vmath,
  common

type Motion* = object
  before*, previous*, current*: array[CogCount, Cog]
  tick*: int32

proc reset*(motion: var Motion, world: World) =
  ## Resets interpolation at load and seek boundaries.
  motion.before = world.cogs
  motion.previous = world.cogs
  motion.current = world.cogs
  motion.tick = world.tick

proc observe*(motion: var Motion, world: World) =
  ## Retains two completed transitions without looking ahead in the sim.
  if world.tick != motion.tick + 1:
    motion.reset(world)
    return
  motion.before = motion.previous
  motion.previous = motion.current
  motion.current = world.cogs
  motion.tick = world.tick

proc position*(motion: Motion, slot: int, fraction, speed: float32): Vec2 =
  ## Rounds turns causally and offsets stationary interaction bumps.
  let
    a = motion.before[slot].tile
    b = motion.previous[slot].tile
    c = motion.current[slot].tile
    p0 = vec2(a.x.float32, a.y.float32)
    p1 = vec2(b.x.float32, b.y.float32)
    p2 = vec2(c.x.float32, c.y.float32)
    t = clamp(fraction, 0'f, 1'f)
  result = p1 + (p2 - p1) * t
  if b != c and b.distance2(c) == 1 and speed <= 50:
    let
      m0 = if a == b: vec2(0) else: (p2 - p0) * 0.5'f
      m1 = p2 - p1
      t2 = t * t
      t3 = t2 * t
    result = (2*t3 - 3*t2 + 1) * p1 + (t3 - 2*t2 + t) * m0 +
      (-2*t3 + 3*t2) * p2 + (t3 - t2) * m1
  elif b == c and speed <= 16 and t > 0 and t < 0.35'f and
    motion.current[slot].feedback in
      {Blocked, Gathered, Deposited, Equipped, Crafted, Captured, Disrupted}:
      let next = c.neighbor(motion.current[slot].direction)
      if next >= 0:
        result += vec2((next.x - c.x).float32, (next.y - c.y).float32) *
          (sin(PI.float32 * t / 0.35'f) * 0.18'f)

proc direction*(motion: Motion, slot: int, fraction, speed: float32): string =
  ## Uses original diagonal artwork during the beginning of a turn.
  const Names = ["s", "n", "e", "s", "w"]
  let
    old = motion.previous[slot].direction
    current = motion.current[slot].direction
  if speed <= 50 and fraction < 0.2'f and old != current:
    if old in {North, South} and current in {East, West}:
      return Names[ord(old)] & Names[ord(current)]
    if current in {North, South} and old in {East, West}:
      return Names[ord(current)] & Names[ord(old)]
  Names[ord(current)]
