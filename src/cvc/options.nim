import
  std/strutils,
  common

from polyworld/cli import BotGroup, addBotSpec, botCount, botSources

type
  Options* = object
    seed*: int32
    recordPath*, replayPath*: string
    groups*: seq[BotGroup]
    headless*, help*, paused*: bool
    speed*: int32

proc number(value, flag: string): int32 =
  ## Parses a signed integer through the game's CLI error boundary.
  try:
    let parsed = parseBiggestInt(value)
    if parsed < int32.low or parsed > int32.high:
      fail(flag & " must fit a signed 32-bit integer")
    result = int32(parsed)
  except ValueError:
    fail(flag & " must be an integer")

proc parseOptions*(arguments: seq[string]): Options =
  ## Accepts Poly World bot groups and space, colon, or equals flag values.
  result.seed = 1
  result.speed = 1
  var i = 0
  while i < arguments.len:
    let argument = arguments[i]
    if argument == "--":
      inc i
      continue
    let separator = argument.find({':', '='})
    let flag = if separator >= 0: argument[0 ..< separator] else: argument
    if flag in ["--headless", "--help"]:
      if separator >= 0:
        fail(flag & " does not take a value")
      if flag == "--headless":
        result.headless = true
      else:
        result.help = true
      inc i
      continue
    if flag notin ["--seed", "--record", "--replay", "--bot", "--bots",
      "--play", "--speed"]:
        fail("unknown argument: " & argument)
    var value: string
    if separator >= 0:
      value = argument[separator + 1 .. ^1]
    else:
      inc i
      if i >= arguments.len or arguments[i].startsWith("--"):
        fail("missing value for " & flag)
      value = arguments[i]
    if value.len == 0:
      fail("missing value for " & flag)
    case flag
    of "--seed":
      result.seed = number(value, flag)
    of "--record":
      result.recordPath = value
    of "--replay":
      result.replayPath = value
    of "--bot", "--bots":
      try:
        result.groups.addBotSpec(value)
      except ValueError:
        fail("invalid bot count: " & value)
    of "--play":
      try:
        result.paused = not parseBool(value)
      except ValueError:
        fail("--play must be true or false")
    of "--speed":
      result.speed = number(value, flag)
      if result.speed <= 0:
        fail("--speed must be positive")
    else:
      discard
    inc i
  if result.help:
    return
  if result.replayPath.len > 0 and result.groups.len > 0:
    fail("--replay cannot be combined with --bots")
  if result.groups.len > 0 and result.groups.botCount != CogCount:
    fail("--bots must fill all " & $CogCount & " Cog slots")

proc sources*(options: Options, fallback: string): array[CogCount, string] =
  ## Expands shared Poly World path:count bot groups into the 32 slots.
  if options.groups.len == 0:
    for source in result.mitems:
      source = fallback
  else:
    try:
      result = options.groups.botSources(CogCount)
    except IOError as error:
      fail("cannot read policy: " & error.msg)
