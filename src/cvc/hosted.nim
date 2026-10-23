import
  polyworld/coworld,
  sims, replays, bots

proc runHosted*() =
  ## Runs staged BASIC seats and publishes the standard CoWorld artifacts.
  let options = coworldOptions(CogCount)
  if options.maximumTicks != MaxTicks:
    raise newException(CoworldError, "FourScore requires 10,000 ticks")
  var sources: array[CogCount, string]
  for slot, group in options.botGroups:
    try:
      sources[slot] = readPlayerSource(group.path)
    except CoworldError as error:
      rejectPlayer(slot, error.msg)
  let
    session = newSession(options.seed)
    policies = newBots(sources)
  while session.world.tick < MaxTicks:
    session.advance(policies.decide(session.world))
  session.save(options.recordPath)
  var scores: seq[int]
  for cog in session.world.cogs:
    scores.add int(session.world.scores[cog.team])
  finishCoworld(CoworldResults(
    scores: scores,
    ticks: session.world.tick,
    seed: options.seed,
    outcome: "time_limit"
  ))
