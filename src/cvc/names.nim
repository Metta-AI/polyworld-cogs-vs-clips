import std/strutils

const CogNames = block:
  var names: seq[string]
  for line in staticRead("../../data/cog_names.txt").splitLines():
    let words = line.splitWhitespace()
    if words.len >= 2 and not line.startsWith("#"):
      names.add(words[0] & " " & $words[1][0] & ".")
  names

proc cogName*(slot: int, seed: int32): string =
  ## Assigns stable original display names without consuming simulation RNG.
  CogNames[int((abs(seed.int64) + slot.int64) mod CogNames.len.int64)]

proc controlHint*(name: string): string =
  ## Describes the actual ported behavior of each original control icon.
  case name
  of "ui/rewindToStart": "First tick"
  of "ui/stepBack": "Previous tick"
  of "ui/play": "Play (Space)"
  of "ui/pause": "Pause (Space)"
  of "ui/stepForward": "Next tick (.)"
  of "ui/rewindToEnd": "Last recorded tick"
  of "ui/grid": "Grid and cog names"
  of "ui/eye": "Current vision"
  of "ui/cloud": "Exploration fog"
  of "ui/move": "Manual control: click a destination or use WASD (live only)"
  of "ui/queue": "Append manual waypoints"
  of "ui/repeat": "Loop replay"
  of "ui/soundMute": "Sound is not enabled"
  of "vibe/default", "vibe/heart", "vibe/gear": "Select and follow a cog"
  of "vibe/miner": "Select and follow a miner"
  of "vibe/aligner": "Select and follow an aligner"
  of "vibe/scrambler": "Select and follow a scrambler"
  of "vibe/scout": "Select and follow a scout"
  else: ""
