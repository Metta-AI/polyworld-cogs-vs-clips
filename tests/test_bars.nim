import cvc/bars

doAssert changedPip(50, 60, 100, 10, 5)
doAssert changedPip(60, 50, 100, 10, 5)
doAssert changedPip(51, 50, 100, 10, 4)
doAssert not changedPip(50, 50, 100, 10, 4)
doAssert not changedPip(0, 0, 100, 10, 0)
echo "Gain, loss and sub-pip flashes match MettaScope."
