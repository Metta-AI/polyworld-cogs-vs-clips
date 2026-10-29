REM Safa CNN/GN/LSTM using generic Polyworld tensor operations.
dim shape1(0)
dim shape3(2)
sub initializeSafa()
  wconv1 = tensorLoad("conv1")
  wbias1 = tensorLoad("bias1")
  wnorm1 = tensorLoad("norm1")
  wshift1 = tensorLoad("shift1")
  wconv2 = tensorLoad("conv2")
  wbias2 = tensorLoad("bias2")
  wnorm2 = tensorLoad("norm2")
  wshift2 = tensorLoad("shift2")
  wimage = tensorLoad("image")
  wimageBias = tensorLoad("imageBias")
  wcenter = tensorLoad("center")
  wcenterBias = tensorLoad("centerBias")
  winput = tensorLoad("input")
  wrecurrent = tensorLoad("recurrent")
  winputBias = tensorLoad("inputBias")
  wrecurrentBias = tensorLoad("recurrentBias")
  wactor = tensorLoad("actor")
  wactorBias = tensorLoad("actorBias")
  wcritic = tensorLoad("critic")
  wcriticBias = tensorLoad("criticBias")
  wcenterIndices = tensorLoad("centerIndices")
  shape3(0) = 134
  shape3(1) = 13
  shape3(2) = 13
  grid = tensorCreate("float32", shape3)
  shape3(0) = 64
  shape3(1) = 7
  shape3(2) = 7
  first = tensorCreate("float32", shape3)
  shape3(0) = 128
  shape3(1) = 4
  shape3(2) = 4
  second = tensorCreate("float32", shape3)
  shape1(0) = 2048
  flat = tensorCreate("float32", shape1)
  shape1(0) = 134
  own = tensorCreate("float32", shape1)
  shape1(0) = 256
  imageOut = tensorCreate("float32", shape1)
  shape1(0) = 256
  ownOut = tensorCreate("float32", shape1)
  shape1(0) = 512
  joined = tensorCreate("float32", shape1)
  shape1(0) = 512
  hidden = tensorCreate("float32", shape1)
  shape1(0) = 512
  cell = tensorCreate("float32", shape1)
  shape1(0) = 2048
  inputs = tensorCreate("float32", shape1)
  shape1(0) = 2048
  previous = tensorCreate("float32", shape1)
  shape1(0) = 2048
  gates = tensorCreate("float32", shape1)
  shape1(0) = 512
  inputGate = tensorCreate("float32", shape1)
  shape1(0) = 512
  forgetGate = tensorCreate("float32", shape1)
  shape1(0) = 512
  candidate = tensorCreate("float32", shape1)
  shape1(0) = 512
  outputGate = tensorCreate("float32", shape1)
  shape1(0) = 512
  retained = tensorCreate("float32", shape1)
  shape1(0) = 512
  incoming = tensorCreate("float32", shape1)
  shape1(0) = 512
  activated = tensorCreate("float32", shape1)
  shape1(0) = 5
  logits = tensorCreate("float32", shape1)
  shape1(0) = 1
  value = tensorCreate("float32", shape1)
  shape1(0) = 1
  maximum = tensorCreate("float32", shape1)
  shape1(0) = 5
  probabilities = tensorCreate("float32", shape1)
  shape1(0) = 22646
  gridFlat = tensorCreate("float32", shape1)
  epsilon = tensorScalar("float32", "0.00001")
end sub

sub forwardSafa()
  tensorConv2d(grid, wconv1, wbias1, 2, 1, first)
  tensorGroupNorm(first, wnorm1, wshift1, 1, epsilon, first)
  tensorRelu(first, first)
  tensorConv2d(first, wconv2, wbias2, 2, 1, second)
  tensorGroupNorm(second, wnorm2, wshift2, 1, epsilon, second)
  tensorRelu(second, second)
  tensorCopySlice(second, 0, flat, 0, 2048)
  tensorDense(flat, wimage, wimageBias, imageOut)
  tensorRelu(imageOut, imageOut)
  tensorCopySlice(grid, 0, gridFlat, 0, 22646)
  tensorGather(gridFlat, wcenterIndices, own)
  tensorDense(own, wcenter, wcenterBias, ownOut)
  tensorRelu(ownOut, ownOut)
  tensorCopySlice(imageOut, 0, joined, 0, 256)
  tensorCopySlice(ownOut, 0, joined, 256, 256)
  tensorDense(joined, winput, winputBias, inputs)
  tensorDense(hidden, wrecurrent, wrecurrentBias, previous)
  tensorAdd(inputs, previous, gates)
  tensorSlice(gates, 0, 512, inputGate)
  tensorSlice(gates, 512, 512, forgetGate)
  tensorSlice(gates, 1024, 512, candidate)
  tensorSlice(gates, 1536, 512, outputGate)
  tensorSigmoid(inputGate, inputGate)
  tensorSigmoid(forgetGate, forgetGate)
  tensorTanh(candidate, candidate)
  tensorSigmoid(outputGate, outputGate)
  tensorMultiply(forgetGate, cell, retained)
  tensorMultiply(inputGate, candidate, incoming)
  tensorAdd(retained, incoming, cell)
  tensorTanh(cell, activated)
  tensorMultiply(outputGate, activated, hidden)
  tensorDense(hidden, wactor, wactorBias, logits)
  tensorDense(hidden, wcritic, wcriticBias, value)
end sub

if initialized = 0 then
  initializeSafa()
  initialized = 1
  print "Safa BASIC tensor policy initialized"
end if
observationTensor(3, grid)
forwardSafa()
steps = steps + 1
if self(1) = 9999 then
  print "Safa BASIC tensor inference steps: "; steps
end if
best = tensorArgmax(logits)
tensorSlice(logits, best, 1, maximum)
tensorSubtract(logits, maximum, probabilities)
tensorExp(probabilities, probabilities)
weights = tensorExport(probabilities)
total = 0.0
for i = 0 to 4
  total = total + weights(i)
next i
draw = (randomInt(16384) / 16384.0) * total
chosen = 4
for i = 0 to 4
  draw = draw - weights(i)
  if draw <= 0.0 then
    chosen = i
    exit for
  end if
next i
REM Original action order: rest, north, south, west, east.
if chosen = 2 then
  chosen = 3
elseif chosen = 3 then
  chosen = 4
elseif chosen = 4 then
  chosen = 2
end if
act(chosen)
