import cvc/[replays, bots, profiles]

let
  session = newSession(1)
  policies = newBots()
for tick in 0 ..< 1020:
  if tick == 1000:
    startCapture()
  session.advance(policies.decide(session.world))
finishCapture("out/fourscore-engine-trace.json")
echo "Captured FourScore ticks 1001 through 1020."
