proc changedSegment*(current, previous, maximum, divisions, segment: int):
    tuple[first, last: float32] =
  ## Returns the exact changed interval within one inspector segment.
  let
    scale = divisions.float32 / max(1, maximum).float32
    now = current.float32 * scale
    before = previous.float32 * scale
  result.first = clamp(min(now, before) - segment.float32, 0'f, 1'f)
  result.last = clamp(max(now, before) - segment.float32, 0'f, 1'f)

proc changedPip*(current, previous, maximum, divisions, pip: int): bool =
  ## Matches MettaScope's whole-pip and sub-pip change highlights.
  let
    now = clamp(current * divisions div max(1, maximum), 0, divisions)
    before = clamp(previous * divisions div max(1, maximum), 0, divisions)
  (pip >= min(now, before) and pip < max(now, before)) or
    (current != previous and now == before and now > 0 and pip == now - 1)
