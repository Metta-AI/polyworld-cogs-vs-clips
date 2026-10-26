import cvc/bars

doAssert changedPip(50, 60, 100, 10, 5)
doAssert changedPip(60, 50, 100, 10, 5)
doAssert changedPip(51, 50, 100, 10, 4)
doAssert not changedPip(50, 50, 100, 10, 4)
doAssert not changedPip(0, 0, 100, 10, 0)
echo "Gain, loss and sub-pip flashes match MettaScope."

let
  loss = changedSegment(98, 99, 100, 10, 9)
  gain = changedSegment(99, 98, 100, 10, 9)
  other = changedSegment(98, 99, 100, 10, 8)
  unchanged = changedSegment(98, 98, 100, 10, 9)
doAssert abs(loss.first - 0.8'f) < 0.00001'f
doAssert abs(loss.last - 0.9'f) < 0.00001'f
doAssert gain == loss
doAssert other.first == other.last
doAssert unchanged.first == unchanged.last
let
  boundary = changedSegment(89, 91, 100, 10, 9)
  below = changedSegment(89, 91, 100, 10, 8)
doAssert boundary.first == 0
doAssert abs(boundary.last - 0.1'f) < 0.00001'f
doAssert abs(below.first - 0.9'f) < 0.00001'f
doAssert below.last == 1
echo "Inspector flashes stay on the fractional changing edge."
