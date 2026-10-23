import
  std/[monotimes, times, strutils, math],
  silky, vmath, chroma,
  sims, replays, bots, terrains

const
  Background = rgbx(12, 20, 26, 255)
  Ink = rgbx(237, 216, 130, 255)
  Muted = rgbx(174, 183, 168, 255)
  Mint = rgbx(92, 224, 176, 255)
  Coral = rgbx(241, 114, 100, 255)
  RoleNames: array[Role, string] = [
    "Cog", "Miner", "Aligner", "Scrambler", "Scout"
  ]
  RoleSprites: array[Role, string] = [
    "agent", "miner", "aligner", "scrambler", "scout"
  ]
  DirectionNames: array[Action, string] = ["s", "n", "e", "s", "w"]
  Speeds = [1.0, 2.0, 5.0, 10.0]

type
  Client = ref object
    session: Session
    policies: Bots
    window: Window
    sk: Silky
    paused: bool
    speed: int
    selected: int
    inspected: int
    takeover: bool
    follow: bool
    crew: bool
    zoom: float32
    center: Vec2
    accumulator: float64
    lastTime: MonoTime
    previous: array[CogCount, int32]
    ground: Terrain
    pipes: seq[tuple[tile: int32, sprite: string, owner: Owner]]
    territory: array[TileCount, Owner]
    owners: seq[Owner]
    message: string
    recordPath: string

when defined(emscripten):
  proc download(path: cstring) {.importc: "cvcDownload", nodecl.}
  {.emit: """
#include <emscripten.h>
EM_JS(void, cvcDownload, (const char* path), {
  const name = UTF8ToString(path);
  const blob = new Blob([FS.readFile(name)], {type:'application/octet-stream'});
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url; link.download = 'cvc.replay'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
""".}

proc label(client: Client, value: string, x, y: float32,
    color = Ink, title = false) =
  ## Draws text using the bundled atlas font.
  discard client.sk.drawText(
    if title: "Title" else: "Default",
    value, vec2(x, y), color
  )

proc size(client: Client): Vec2 =
  ## Returns logical pixels independently of display density.
  client.window.size.vec2 / client.sk.uiScale

proc mouse(client: Client): Vec2 =
  ## Returns the pointer in logical pixels.
  client.window.mousePos.vec2 / client.sk.uiScale

proc hit(client: Client, x, y, width, height: float32): bool =
  ## Checks whether the mouse lies inside a screen rectangle.
  let mouse = client.mouse()
  mouse.x >= x and mouse.y >= y and mouse.x < x + width and
    mouse.y < y + height

proc button(client: Client, value: string, x, y, width: float32,
    active = false): bool =
  ## Draws a compact button and returns its click edge.
  let hover = client.hit(x, y, width, 32)
  client.sk.draw9Patch(
    if active: "theme/button.down.9patch"
    elif hover: "theme/button.hover.9patch"
    else: "theme/button.9patch",
    8, vec2(x, y), vec2(width, 32)
  )
  client.label(value, x + 10, y + 6, if active: Mint else: Ink)
  hover and client.window.buttonPressed[MouseLeft]

proc sprite(client: Client, name: string, position: Vec2, size: float32,
    tint = Ink) =
  ## Draws one atlas sprite scaled independently of simulation coordinates.
  let key = name
  if key notin client.sk.atlas.entries:
    return
  let entry = client.sk.atlas.entries[key]
  client.sk.drawQuad(
    position, vec2(size, size),
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32), tint
  )

proc image(client: Client, name: string, position, size: Vec2,
    tint = rgbx(255, 255, 255, 255)) =
  ## Draws a rectangular original HUD image without changing its aspect.
  let entry = client.sk.atlas.entries[name]
  client.sk.drawQuad(
    position, size,
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32), tint
  )

proc viewport(client: Client): Vec2 =
  ## Uses the entire window for the world beneath the themed HUD.
  client.size

proc screen(client: Client, tile: int32): Vec2 =
  ## Converts a simulation tile center into client screen coordinates.
  client.size / 2 +
    (vec2(tile.x.float32 + 0.5, tile.y.float32 + 0.5) -
    client.center) * client.zoom

proc worldSprite(client: Client, name: string, tile: int32,
    tint = rgbx(255, 255, 255, 255)) =
  ## Preserves MettaScope's original 128-pixel world scale and proportions.
  let
    entry = client.sk.atlas.entries[name]
    size = vec2(entry.width.float32, entry.height.float32) *
      (client.zoom / 128)
    position = client.screen(tile) - size / 2
  if position.x + size.x < 0 or position.y + size.y < 0 or
    position.x > client.size.x or position.y > client.size.y:
      return
  client.image(name, position, size, tint)

proc groundSlice(client: Client, name: string, tile: int32,
    column, row: int) =
  ## Samples one 128-pixel cell from the original terrain sheets.
  let
    entry = client.sk.atlas.entries[name]
    position = client.screen(tile) - vec2(client.zoom / 2)
  client.sk.drawQuad(
    position, vec2(client.zoom + 0.02'f),
    vec2(float32(entry.x + column * 128), float32(entry.y + row * 128)),
    vec2(128), rgbx(255, 255, 255, 255)
  )

proc refreshTerritory(client: Client) =
  ## Rebuilds the presentation overlay only when ownership changes.
  var changed = client.owners.len != client.session.world.stations.len
  if not changed:
    for i, station in client.session.world.stations:
      if client.owners[i] != station.owner:
        changed = true
        break
  if changed:
    client.owners.setLen(client.session.world.stations.len)
    for i, station in client.session.world.stations:
      client.owners[i] = station.owner
    for tile in 0 ..< TileCount:
      client.territory[tile] = client.session.world.territory(int32(tile))
    client.pipes = client.session.world.pipes()

proc step(client: Client) =
  ## Advances one lockstep frame, optionally replacing one policy action.
  for i, cog in client.session.world.cogs:
    client.previous[i] = cog.tile
  if client.session.playback:
    client.session.advance()
  else:
    var actions = client.policies.decide(client.session.world)
    if client.takeover:
      actions[client.selected] = Rest
      for pair in [(KeyW, North), (KeyD, East), (KeyS, South), (KeyA, West),
        (KeyUp, North), (KeyRight, East), (KeyDown, South), (KeyLeft, West)]:
          if client.window.buttonDown[pair[0]]:
            actions[client.selected] = pair[1]
    client.session.advance(actions)

proc saveReplay(client: Client) =
  ## Saves locally or downloads the current action tape in a browser.
  let path =
    if client.recordPath.len > 0: client.recordPath else: "cvc.replay"
  client.session.save(path)
  when defined(emscripten):
    download(path.cstring)
  client.message = "Saved " & path

proc drawMap(client: Client) =
  ## Draws territory tiles, stations, interpolated Cogs, and action feedback.
  let
    area = client.viewport()
    size = client.zoom
    world = client.session.world
  client.refreshTerritory()
  client.image("starfield/starfield", vec2(0), area)
  client.image("starfield/clouds", vec2(0), area, rgbx(110, 110, 110, 110))
  for tile in 0'i32 ..< TileCount:
    let position = client.screen(tile)
    if position.x < -size or position.x > area.x + size or
      position.y < -size or position.y > area.y + size:
        continue
    client.groundSlice("terrain/repeating.sand", tile,
      int(tile.x mod 8), int(tile.y mod 8))
  for splat in client.ground.splats:
    client.worldSprite("terrain/splat" & $splat.variant, splat.tile,
      rgbx(100, 100, 100, 100))
  for station in world.stations:
    let stamp =
      case station.kind
      of Hub: "terrain/stamp.hub"
      of Junction: "terrain/stamp.junction"
      of Extractor: "terrain/stamp." & ($station.element).toLowerAscii
      of Ship: "objects/ship.shadow"
      of Gear: ""
    if stamp.len > 0:
      client.worldSprite(stamp, station.tile)
  # The inverse mask overlays cliffs after decals, clipping all ground layers.
  for tile in 0'i32 ..< TileCount:
    let position = client.screen(tile)
    if position.x < -size or position.x > area.x + size or
      position.y < -size or position.y > area.y + size:
        continue
    let edge = int(client.ground.edges[tile])
    client.groundSlice("terrain/cliffs", tile, edge mod 7, edge div 7)
    if not world.tiles[tile].wall and client.territory[tile] != Neutral:
      let color =
        if client.territory[tile] == Cogs: rgbx(8, 35, 23, 40)
        else: rgbx(45, 8, 8, 48)
      client.sk.drawRect(position - vec2(size / 2), vec2(size), color)
  for pipe in client.pipes:
    client.worldSprite(pipe.sprite, pipe.tile,
      if pipe.owner == Cogs: rgbx(80, 165, 130, 180)
      else: rgbx(170, 90, 70, 180))
  for i, station in world.stations:
    if station.kind == Extractor and station.stock == 0:
      continue
    let position = client.screen(station.tile)
    if position.x < -size or position.x > area.x + size or
      position.y < -size or position.y > area.y + size:
        continue
    var name: string
    case station.kind
    of Hub: name = "hub"
    of Junction:
      name = if station.owner == Neutral: "junction" else: "junction.working"
    of Ship: name = "ship"
    of Extractor: name = ($station.element).toLowerAscii & "_extractor"
    of Gear: name = ($station.role).toLowerAscii
    let tint =
      if station.owner == Clips: rgbx(255, 180, 175, 255)
      else: rgbx(255, 255, 255, 255)
    client.worldSprite("objects/" & name, station.tile, tint)
    if i == client.inspected:
      client.sk.drawRect(position + vec2(-size, size), vec2(size * 2, 2), Mint)
  let fraction =
    if client.paused: 1.0'f
    else: float32(clamp(client.accumulator * TickRate, 0.0, 1.0))
  for i, cog in world.cogs:
    let
      previous = client.screen(client.previous[i])
      current = client.screen(cog.tile)
      position = previous + (current - previous) * fraction
    if i == client.selected:
      client.sprite("selection", position - vec2(size), size * 2, Mint)
    client.sprite(
      "agents/" & RoleSprites[cog.role] & "." & DirectionNames[cog.direction],
      position - vec2(size), size * 2, rgbx(255, 255, 255, 255)
    )
    if size >= 15:
      client.label($(i + 1), position.x - 4, position.y - size - 13, Mint)
    if cog.feedback in {Gathered, Deposited, Crafted, Captured, Disrupted}:
      client.sk.drawRect(position + vec2(-size / 2, size),
        vec2(size, 2), Mint)

proc drawInspector(client: Client) =
  ## Draws original metal HUD panels over the live simulation.
  let
    width = client.size.x
    height = client.size.y
    world = client.session.world
    cog = world.cogs[client.selected]
    compact = width < 1000
    crewX = width - 284
    crewY = height - (if compact: 345 else: 304)
    detailX = width / 2 - 218
    detailY = height - (if compact: 345 else: 304)
  client.image("ui/panel_center", vec2(detailX, detailY), vec2(436, 247))
  client.label("COG " & $(client.selected + 1) & " / " & RoleNames[cog.role],
    detailX + 26, detailY + 24)
  client.label($cog.feedback, detailX + 26, detailY + 50, Muted)
  for i, pair in [(cog.hp, cog.role.maxHp),
    (cog.energy, cog.role.maxEnergy)]:
      let y = detailY + 78 + float32(i) * 29
      client.label(if i == 0: "HP" else: "EN", detailX + 26, y)
      client.sk.draw9Patch("theme/progressBar.body.9patch", 5,
        vec2(detailX + 60, y + 3), vec2(132, 13))
      client.sk.draw9Patch("theme/progressBar.progress.9patch", 5,
        vec2(detailX + 60, y + 3),
        vec2(max(10'f, 132 * pair[0].float32 / pair[1].float32), 13),
        if i == 0: Mint else: Ink)
      client.label($pair[0], detailX + 202, y)
  client.sprite("resources/heart", vec2(detailX + 24, detailY + 140), 26)
  client.label($cog.hearts, detailX + 55, detailY + 144)
  client.label("Cargo " & $cog.carried, detailX + 103, detailY + 144)
  client.sprite("profiles/" & RoleSprites[cog.role],
    vec2(detailX + 291, detailY + 28), 116,
    rgbx(255, 255, 255, 255))
  if client.inspected >= 0:
    let station = world.stations[client.inspected]
    client.label($station.kind & " / " & $station.owner &
      " / " & $station.stock, detailX + 26, detailY + 174, Muted)
  if compact:
    if client.button(if client.crew: "Cog" else: "Crew",
      detailX + 303, detailY + 172, 96, client.crew):
        client.crew = not client.crew
  if not compact or client.crew:
    client.sk.draw9Patch("hud/frame", 26,
      vec2(if compact: detailX else: crewX, crewY), vec2(284, 210))
    client.label("CREW", (if compact: detailX else: crewX) + 26, crewY + 22)
    for i, member in world.cogs:
      let
        x = (if compact: detailX else: crewX) + 24 + float32(i mod 2) * 118
        y = crewY + 50 + float32(i div 2) * 32
      if client.button($(i + 1) & " " & RoleNames[member.role],
        x, y, 113, i == client.selected):
          client.selected = i
          client.inspected = -1
  if compact:
    return
  let
    miniY = height - 304
    miniPos = vec2(22, miniY + 24)
  client.sk.draw9Patch("hud/frame", 22,
    vec2(0, miniY), vec2(220, 218))
  for tile in 0'i32 ..< TileCount:
    let color =
      if world.tiles[tile].wall: Background
      elif client.territory[tile] == Cogs: rgbx(92, 117, 84, 255)
      elif client.territory[tile] == Clips: rgbx(132, 86, 72, 255)
      else: rgbx(91, 84, 70, 255)
    client.sk.drawRect(
      miniPos + vec2(tile.x.float32 * 2, tile.y.float32 * 2),
      vec2(2, 2), color
    )
  for member in world.cogs:
    client.sk.drawRect(
      miniPos + vec2(member.tile.x.float32 * 2,
        member.tile.y.float32 * 2), vec2(3, 3), Mint
    )
  if client.hit(miniPos.x, miniPos.y, Width * 2, Height * 2) and
    client.window.buttonPressed[MouseLeft]:
      client.center = (client.mouse() - miniPos) / 2
      client.follow = false

proc drawChrome(client: Client) =
  ## Draws scores, resources, and the Poly World action-tape transport.
  let
    width = client.size.x
    compact = width < 1000
    bottom = client.size.y - (if compact: 92 else: 48)
    world = client.session.world
  client.sk.draw9Patch("hud/frame", 24,
    vec2(0), vec2(218, 151))
  client.label("COGS / CLIPS", 26, 22)
  client.label("COGS", 26, 54, Mint)
  client.label(formatFloat(world.score.float / MaxTicks.float,
    ffDecimal, 2), 140, 54, Mint)
  client.label("CLIPS", 26, 79, Coral)
  client.label(formatFloat(world.clipsScore.float / MaxTicks.float,
    ffDecimal, 2), 140, 79, Coral)
  client.label("Seed " & $world.seed & "  /  " &
    (if world.tick mod DayLength < 100: "Day" else: "Night"), 26, 111, Muted)
  client.sk.draw9Patch("hud/frame", 24,
    vec2(width - 284, 0), vec2(284, 127))
  client.label("SHARED BANK", width - 258, 20)
  for element in Element:
    let x = width - 258 + float32(ord(element)) * 62
    client.sprite("resources/" & ($element).toLowerAscii,
      vec2(x, 45), 28, rgbx(255, 255, 255, 255))
    client.label($world.bank[element], x, 81)
  client.image("ui/barstretch", vec2(0, bottom), vec2(width, if compact: 92 else: 48))
  if client.button(if client.paused: "Play" else: "Pause", 16, bottom + 7, 66):
    client.paused = not client.paused
  if client.button("Step", 86, bottom + 7, 58):
    client.paused = true
    client.step()
  if client.button($int(Speeds[client.speed]) & "x", 148, bottom + 7, 48):
    client.speed = (client.speed + 1) mod Speeds.len
  if client.button("Follow", 200, bottom + 7, 72, client.follow):
    client.follow = not client.follow
  if not client.session.playback:
    if client.button(if client.takeover: "Release" else: "Control",
      276, bottom + 7, 82, client.takeover):
        client.takeover = not client.takeover
  if client.button("Save tape", 362, bottom + 7, 96):
    client.saveReplay()
  if not client.session.playback and
    client.button("Watch", 462, bottom + 7, 72):
      client.session = fromReplay(client.session.tape)
      client.paused = true
      client.takeover = false
      for i, cog in client.session.world.cogs:
        client.previous[i] = cog.tile
  let
    start = if compact: 16'f else: 552'f
    trackY = bottom + (if compact: 49'f else: 7'f)
    barWidth = max(40'f, width - start - 156)
    duration = if client.session.playback:
      client.session.tape.hashes.len.float32 else: MaxTicks.float32
  client.sk.draw9Patch("theme/scrubber.track.9patch", 8,
    vec2(start, trackY), vec2(barWidth, 32))
  client.sk.draw9Patch("theme/button.down.9patch", 8,
    vec2(start + (barWidth - 16) * world.tick.float32 /
      max(1'f, duration), trackY), vec2(16, 32))
  client.label($world.tick & " / " & $MaxTicks, width - 142, trackY + 8)
  if client.session.playback and client.hit(start, trackY, barWidth, 32) and
    client.window.buttonPressed[MouseLeft]:
      try:
        let fraction = (client.mouse.x - start) / barWidth
        client.session.seek(int32(fraction * duration))
        for i, cog in client.session.world.cogs:
          client.previous[i] = cog.tile
      except CvcError as error:
        client.message = error.msg
      client.paused = true
  if client.message.len > 0:
    client.sk.draw9Patch("theme/tooltip.9patch", 8,
      vec2(width / 2 - 220, 12), vec2(440, 34))
    client.label(client.message, width / 2 - 206, 21)

proc overHud(client: Client): bool =
  ## Prevents world clicks and zoom from passing through HUD panels.
  let
    width = client.size.x
    height = client.size.y
  client.hit(0, 0, 218, 151) or
    client.hit(width - 284, 0, 284, 127) or
    client.hit(width / 2 - 218,
      height - (if width < 1000: 345 else: 304), 436, 247) or
    (width >= 1000 and (
      client.hit(0, height - 304, 220, 218) or
      client.hit(width - 284, height - 304, 284, 210))) or
    client.hit(0, height - (if width < 1000: 92 else: 48), width, 92)

proc input(client: Client) =
  ## Handles camera navigation, selection, and keyboard transport.
  let
    window = client.window
    area = client.viewport()
    mouse = client.mouse()
  if window.buttonPressed[KeySpace]:
    client.paused = not client.paused
  if window.buttonPressed[KeyPeriod]:
    client.paused = true
    client.step()
  if not client.overHud():
    if window.scrollDelta.y != 0:
      client.zoom = clamp(client.zoom *
        pow(1.0015'f, window.scrollDelta.y), 5'f, 64'f)
    if window.buttonDown[MouseRight]:
      client.center -= window.mouseDelta.vec2 /
        (client.zoom * client.sk.uiScale)
      client.follow = false
    if window.buttonPressed[MouseLeft]:
      let position = (mouse - area / 2) /
        client.zoom + client.center
      let tile = tileAt(int32(floor(position.x)), int32(floor(position.y)))
      if tile >= 0:
        client.inspected = client.session.world.tiles[tile].station
        for i, cog in client.session.world.cogs:
          if cog.tile.distance2(tile) <= 2:
            client.selected = i
            client.inspected = -1
  if client.follow:
    let tile = client.session.world.cogs[client.selected].tile
    client.center = vec2(tile.x.float32, tile.y.float32)

proc frame(client: Client) =
  ## Runs bounded catch-up ticks and renders one independent client frame.
  let
    now = getMonoTime()
    elapsed = min(0.1, (now - client.lastTime).inMicroseconds.float / 1_000_000)
  client.lastTime = now
  client.sk.uiScale = client.window.contentScale
  try:
    client.input()
    if not client.paused:
      client.accumulator += elapsed * Speeds[client.speed]
      var steps = 0
      while client.accumulator >= 1.0 / TickRate and steps < 20:
        client.step()
        client.accumulator -= 1.0 / TickRate
        inc steps
      if client.session.world.tick >= MaxTicks or
        (client.session.playback and client.session.world.tick >=
        int32(client.session.tape.hashes.len)):
          client.paused = true
    client.sk.beginUi(client.window, client.window.size)
    client.sk.clearScreen(Background)
    client.drawMap()
    client.drawInspector()
    client.drawChrome()
    client.sk.endUi()
    client.window.swapBuffers()
  except CvcError as error:
    client.paused = true
    client.message = error.msg
    echo error.msg

proc runClient*(session: Session, policy, recordPath: string) =
  ## Opens the native or browser client with identical simulation code.
  let window = newWindow("Cogs / Clips", ivec2(1440, 960))
  window.makeContextCurrent()
  loadExtensions()
  let client = Client(
    session: session,
    policies: newBots(policy),
    window: window,
    sk: newSilky(window, "data/atlas.png"),
    center: vec2(44, 44),
    zoom: 26,
    ground: session.world.terrain(),
    inspected: -1,
    lastTime: getMonoTime(),
    recordPath: recordPath
  )
  client.sk.uiScale = window.contentScale
  for i, cog in session.world.cogs:
    client.previous[i] = cog.tile
  window.onFrame = proc() =
    ## Dispatches one frame from the platform event loop.
    client.frame()
  window.onFileDrop = proc(fileName, fileData: string) =
    ## Opens a dropped action replay in read-only mode.
    try:
      client.session = loadBytes(fileData)
      client.paused = true
      client.takeover = false
      client.owners.setLen(0)
      client.ground = client.session.world.terrain()
      for i, cog in client.session.world.cogs:
        client.previous[i] = cog.tile
      client.message = "Loaded " & fileName
    except CvcError as error:
      client.message = error.msg
  when defined(emscripten):
    discard
  while not window.closeRequested:
    pollEvents()
  if recordPath.len > 0:
    client.session.save(recordPath)
