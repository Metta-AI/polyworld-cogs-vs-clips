import chroma

const
  Yellow* = rgbx(241, 196, 15, 255)
  DarkGray* = rgbx(127, 140, 141, 255)

proc getTeamColor*(team: int): ColorRGBX =
  ## Uses MettaScope's cogs and clips palette without replay team tags.
  case team
  of 1: rgbx(239, 184, 80, 255)
  of 2: rgbx(231, 76, 60, 255)
  else: rgbx(255, 255, 255, 255)
