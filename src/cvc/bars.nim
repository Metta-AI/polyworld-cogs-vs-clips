proc changedPip*(current, previous, maximum, divisions, pip: int): bool =
  ## Matches MettaScope's whole-pip and sub-pip change highlights.
  let
    now = clamp(current * divisions div max(1, maximum), 0, divisions)
    before = clamp(previous * divisions div max(1, maximum), 0, divisions)
  (pip >= min(now, before) and pip < max(now, before)) or
    (current != previous and now == before and now > 0 and pip == now - 1)
