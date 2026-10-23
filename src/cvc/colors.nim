import chroma

const
  Yellow* = rgbx(241, 196, 15, 255)
  DarkGray* = rgbx(127, 140, 141, 255)

proc getTeamColor*(team: int): ColorRGBX =
  ## Uses MettaScope's four-team palette without replay team tags.
  case team
  of 1: rgbx(231, 76, 60, 255)
  of 2: rgbx(52, 152, 219, 255)
  of 3: rgbx(46, 204, 113, 255)
  of 4: rgbx(239, 184, 80, 255)
  else: rgbx(255, 255, 255, 255)
