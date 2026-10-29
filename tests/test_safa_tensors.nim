import
  std/[strutils, times],
  bassy,
  polyworld/[policies, tensors],
  cvc/[bots, common, sims]

proc floats(bytes: string): seq[float32] =
  ## Decodes the little-endian float32 reference fixture.
  doAssert bytes.len mod 4 == 0
  for i in countup(0, bytes.len - 1, 4):
    var raw: uint32
    for j in 0 ..< 4:
      raw = raw or (uint32(ord(bytes[i + j])) shl (j * 8))
    result.add cast[float32](raw)

let
  package = readFile("out/safa/safa-tensors.zip")
  policy = loadPolicy(package)
  inputs = floats(readFile("out/safa/parity-inputs.bin"))
  expected = floats(readFile("out/safa/parity-outputs.bin"))
  source = policy.source.split("if initialized = 0 then")[0] & """
if initialized = 0 then
  initializeSafa()
  initialized = 1
end if
fixture(grid)
forwardSafa()
"""
var
  step = 0
  host = initHost()
  limits = defaultLimits()
  difference = 0.0'f
limits.maxWorkUnits = 250_000
host.addTensorFunctions(policy)
discard host.addFunction("fixture", 1,
  proc(runtime: Runtime, args: openArray[Value]): Value =
    ## Supplies exact PyTorch inputs without numeric BASIC conversion.
    runtime.writeFloats(args[0], inputs.toOpenArray(
      step * 22646, (step + 1) * 22646 - 1))
    args[0], 1)
var runtime = initRuntime(compile(source, host, limits), host, limits)
for frame in 0 ..< 3:
  step = frame
  runtime.restart()
  discard runtime.run()
  var actual: seq[float32]
  for name in ["logits", "value", "hidden", "cell"]:
    let blob = runtime.getBlob(runtime.getGlobalValue(name))
    actual.add floats(blob[12 + ord(blob[9]) * 4 .. ^1])
  for i, value in actual:
    let error = abs(value - expected[frame * actual.len + i])
    difference = max(difference, error)
    doAssert error < 0.002'f, $frame & " " & $i & " error " & $error
  echo "Tensor recurrent frame ", frame, ", work ", runtime.workUsed()
echo "BASIC tensor PyTorch parity max error: ", difference
let started = epochTime()
var
  world = initWorld(1)
  sources: array[CogCount, string]
for i in 0 ..< CogCount:
  sources[i] = if i < 8: package else: "act(0)"
let players = newBots(sources)
var moves = 0
for tick in 0 ..< 20:
  let actions = players.decide(world)
  for i in 0 ..< 8:
    doAssert players.policyError(i) == "", players.policyError(i)
    if actions[i] != Rest:
      inc moves
  world.tick(actions)
doAssert moves > 0
echo "Eight tensor seats, 20 ticks: ", epochTime() - started, " seconds"
