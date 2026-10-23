import
  std/[monotimes, times, strutils, math],
  silky, vmath, chroma, pixie,
  sims, replays, bots, renders, colors, profiles, timings, scrubs

when defined(emscripten):
  proc runBrowserScript(script: cstring) {.
    importc: "emscripten_run_script", header: "<emscripten.h>".}
    ## Runs presentation notifications in the browser host.

const
  Background = rgbx(12, 20, 26, 255)
  Ink = rgbx(237, 216, 130, 255)
  RoleNames: array[Role, string] = [
    "Cog", "Miner", "Aligner", "Scrambler", "Scout"
  ]
  Speeds = [1.0, 5.0, 10.0, 50.0, 100.0, 1000.0]

type
  Client = ref object
    session: Session
    policies: Bots
    window: Window
    sk: Silky
    paused: bool
    live: bool
    rate: float64
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
    renderer: Renderer
    scrubs: ScrubCache
    pendingSeek, pendingSnap: bool
    pendingTarget: int32
    grid, vision, fog, miniature, repeating, dragging: bool
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
    "pixelated",
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

proc step(client: Client) {.measure.} =
  ## Advances one lockstep frame, optionally replacing one policy action.
  for i, cog in client.session.world.cogs:
    client.previous[i] = cog.tile
  if client.live and client.session.playback and
    client.session.world.tick == int32(client.session.tape.hashes.len):
      client.session.playback = false
  if client.session.playback:
    client.session.advance()
  else:
    var actions = client.policies.decide(client.session.world)
    if client.takeover and client.selected >= 0:
      actions[client.selected] = Rest
      for pair in [(KeyW, North), (KeyD, East), (KeyS, South), (KeyA, West),
        (KeyUp, North), (KeyRight, East), (KeyDown, South), (KeyLeft, West)]:
          if client.window.buttonDown[pair[0]]:
            actions[client.selected] = pair[1]
    client.session.advance(actions)
  client.renderer.observe(client.session.world)

proc saveReplay(client: Client) =
  ## Saves locally or downloads the current action tape in a browser.
  let path =
    if client.recordPath.len > 0: client.recordPath else: "cvc.replay"
  client.session.save(path)
  when defined(emscripten):
    download(path.cstring)
  client.message = "Saved " & path

proc seek(client: Client, target: int32, snap = false) =
  ## Restores a five-percent checkpoint, advancing only for an exact seek.
  client.paused = true
  client.accumulator = 0
  if client.scrubs.points.len == 0 or
    client.scrubs.duration != int32(client.session.tape.hashes.len):
      client.scrubs = beginScrubs(client.session.tape)
  client.pendingSeek = not client.scrubs.available(target, snap)
  if client.pendingSeek:
    client.pendingTarget = target
    client.pendingSnap = snap
    return
  let
    index = client.scrubs.pointAt(target, snap)
    point = client.scrubs.points[index]
    destination =
      if snap:
        point.world.tick
      else:
        clamp(target, 0'i32, client.scrubs.duration)
  client.session.world = point.world
  client.session.playback = true
  client.session.error = ""
  client.renderer.restore(point)
  while client.session.world.tick < destination:
    client.session.advance()
    client.renderer.observe(client.session.world)
  for i, cog in client.session.world.cogs:
    client.previous[i] = cog.tile
  client.takeover = false

proc iconButton(client: Client, pos: Vec2, name: string,
    active = false): bool =
  ## Uses the original 48-pixel toggle artwork and hit region.
  let hover = client.hit(pos.x, pos.y, 48, 48)
  if active or hover:
    client.sk.drawImage(
      if active: "ui/button_main.down" else: "ui/button_main.hover",
      pos - vec2(16))
  client.sprite(name, pos, 48, rgbx(255, 255, 255, 255))
  hover and client.window.buttonReleased[MouseLeft]

proc transport(client: Client, start: Vec2, index: int,
    icon: string, active = false): bool =
  ## Copies the original transport button geometry and pressed treatment.
  let
    pos = start + vec2(index.float32 * 48, 0)
    size = client.sk.getImageSize("ui/transportButton.up")
    hover = client.hit(pos.x, pos.y, size.x, size.y)
    pressed = hover and client.window.buttonReleased[MouseLeft]
    background =
      if active or pressed: "ui/transportButton.down"
      elif hover: "ui/transportButton.hover"
      else: "ui/transportButton.up"
    iconSize = client.sk.getImageSize(icon)
  client.sk.drawImage(background, pos)
  client.sk.drawImage(icon, pos + (size - iconSize) / 2,
    color = if active: rgbx(128, 128, 128, 128)
      else: rgbx(255, 255, 255, 255))
  pressed

proc cell(client: Client, pos: Vec2, value: string, width = 80'f) =
  ## Draws the original inset resource cell and pixel-font digits.
  client.sk.draw9Patch("ui/resource_bg", 16, pos, vec2(width, 40))
  discard client.sk.drawText("pixelated", value, pos + vec2(8, -4),
    Yellow, maxWidth = width - 16, maxHeight = 40,
    clip = false, hAlign = RightAlign, vAlign = MiddleAlign)

proc drawMap(client: Client, mini = false) =
  ## Reads current simulation state through the original GPU render passes.
  let
    size = client.size
    area = if mini: vec4(30, size.y - 390, 300, 300)
      else: vec4(0, 0, size.x, size.y)
    fraction = if client.paused: 1'f
      else: float32(clamp(client.accumulator * TickRate, 0.0, 1.0))
  client.renderer.drawWorld(client.session.world, client.previous,
    fraction, client.selected, client.inspected, client.window.size,
    area, if mini: vec2((Width.float32 - 1) / 2) else: client.center,
    if mini: 300'f / (Width + 10).float32 else: client.zoom,
    mini or client.miniature, client.grid and not mini,
    client.vision, client.fog)

proc drawInspector(client: Client) =
  ## Copies the contextual center panel, reading the selected live Cog.
  if client.selected < 0:
    return
  let
    cog = client.session.world.cogs[client.selected]
    pos = vec2((client.size.x - 623) / 2, client.size.y - 373)
  client.sk.drawImage("ui/panel_center", pos)
  client.label("Cog " & $(client.selected + 1) & " / " &
    RoleNames[cog.role], pos.x + 69, pos.y + 32)
  client.label("BASIC", pos.x + 69, pos.y + 64,
    rgbx(255, 255, 255, 255))
  for i, pair in [(cog.hp, cog.role.maxHp),
    (cog.energy, cog.role.maxEnergy)]:
      let origin = pos + vec2(69, 113 + i.float32 * 32)
      client.label(if i == 0: "HP" else: "EN",
        origin.x, origin.y - 17)
      let bar = origin + vec2(39, 0)
      for edge in [vec4(0, 0, 260, 1), vec4(0, 19, 260, 1),
        vec4(0, 0, 1, 20), vec4(259, 0, 1, 20)]:
          client.sk.drawRect(bar + edge.xy, edge.zw, Yellow)
      let
        divisions = if i == 0: 10 else: 20
        stride = 256'f / divisions.float32
      for j in 0 ..< divisions:
        let fill = clamp(pair[0].float32 / pair[1].float32 *
          divisions.float32 - j.float32, 0'f, 1'f)
        client.sk.drawRect(bar + vec2(2 + j.float32 * stride, 2),
          vec2((stride - 1) * fill, 16), Yellow)
  var item = 0
  for element in Element:
    if cog.cargo[element] <= 0:
      continue
    let offset = pos + vec2(59 + (item mod 3).float32 * 100,
      183 + (item div 3).float32 * 60)
    client.sprite("resources/" & ($element).toLowerAscii, offset, 48,
      rgbx(255, 255, 255, 255))
    client.label($cog.cargo[element], offset.x + 56, offset.y + 8)
    inc item

proc drawChrome(client: Client) =
  ## Preserves MettaScope's panel layout, icons, and single metal timeline.
  let
    width = client.size.x
    height = client.size.y
    world = client.session.world
    right = vec2(width - 559, height - 373)
    left = vec2(0, height - 422)
  client.sk.draw9Patch("ui/panel_topleft", 55, 50, 100, 30,
    vec2(0), vec2(364, 389))
  client.label("Score", 90, 49)
  client.sprite("icons/objects/junction", vec2(238, 61), 32,
    rgbx(255, 255, 255, 255))
  for i, owner in Teams:
    let y = 105 + i.float32 * 44
    var count = 0
    for station in world.stations:
      if station.kind == Junction and station.owner == owner:
        inc count
    client.sk.drawRect(vec2(46, y + 12), vec2(16), getTeamColor(ord(owner)))
    let score = world.scores[owner]
    client.cell(vec2(82, y), formatFloat(score.float / MaxTicks.float,
      ffDecimal, 2), 120)
    client.cell(vec2(214, y), $count)
  client.sk.draw9Patch("ui/panel_topright", 55, 30, 100, 30,
    vec2(width - 488, 0), vec2(488, 395))
  for i, element in [Carbon, Oxygen, Germanium, Silicon]:
    let x = width - 438 + i.float32 * 98
    client.sprite("resources/" & ($element).toLowerAscii,
      vec2(x + 25, 55), 48, rgbx(255, 255, 255, 255))
    for row, team in Teams:
      client.cell(vec2(x + 9, 111 + row.float32 * 44),
        $world.banks[team][element])
  for row, team in Teams:
    client.sk.drawRect(vec2(width - 454, 123 + row.float32 * 44),
      vec2(12), getTeamColor(ord(team)))
  client.image("ui/barstretch", vec2(589, height - 81),
    vec2(max(0'f, width - 1147), 81))
  client.sk.drawImage("ui/panel_bottomleft", left)
  client.sk.drawImage("ui/panel_bottomright", right)
  for (name, offset) in [("bar_stopRight", -8'f), ("bar_spacer", 315'f),
    ("bar_stopLeft", 379'f)]:
      let imageSize = client.sk.getImageSize("ui/" & name)
      client.sk.drawImage("ui/" & name,
        vec2(width - offset - imageSize.x, height - imageSize.y))
  let start = vec2(59, height - 60)
  if client.transport(start, 0, "ui/rewindToStart"):
    client.seek(0)
  if client.transport(start, 1, "ui/stepBack"):
    client.seek(world.tick - 1)
  if client.transport(start, 2,
    if client.paused: "ui/play" else: "ui/pause", not client.paused):
      client.paused = not client.paused
      client.pendingSeek = false
  if client.transport(start, 3, "ui/stepForward"):
    client.paused = true
    client.pendingSeek = false
    client.step()
  if client.transport(start, 4, "ui/rewindToEnd"):
    client.seek(int32(client.session.tape.hashes.len))
  for i, icon in ["grid", "eye", "cloud"]:
    let active = [client.grid, client.vision, client.fog][i]
    if client.iconButton(left + vec2(392, 94 + i.float32 * 88),
      "ui/" & icon, active):
        case i
        of 0: client.grid = not client.grid
        of 1: client.vision = not client.vision
        else: client.fog = not client.fog
  for i in 0 ..< Speeds.len:
    if client.transport(right + vec2(230, 316), i,
      if i == 0: "ui/turtle"
      elif i == Speeds.high: "ui/rabbit"
      else: "ui/speed", Speeds[i] > client.rate):
        client.rate = Speeds[i]
        client.accumulator = 0
  if client.iconButton(right + vec2(174, 44), "ui/move", client.takeover):
    client.takeover = not client.takeover
  if client.iconButton(right + vec2(174, 132), "ui/queue", client.miniature):
    client.miniature = not client.miniature
  if client.iconButton(right + vec2(174, 220), "ui/repeat", client.repeating):
    client.repeating = not client.repeating
  discard client.transport(right + vec2(152, 316), 0, "ui/soundMute", true)
  for i, name in ["default", "heart", "gear", "scrambler", "aligner",
    "miner", "scout"]:
      if client.iconButton(vec2(width - 262 + (i mod 3).float32 * 82,
        height - 328 + (i div 3).float32 * 87), "vibe/" & name):
          for j, cog in world.cogs:
            if (i < 3 or ord(cog.role) == [0, 0, 0, 3, 2, 1, 4][i]):
              client.selected = j
              client.follow = true
              break
  let
    trackStart = 355'f
    trackWidth = max(1'f, width - 853)
    duration = if client.live: MaxTicks.float32
      else: max(1'f, client.session.tape.hashes.len.float32)
    fraction = world.tick.float32 / duration
    knob = vec2(trackStart + fraction * max(1'f, trackWidth - 87) - 32,
      height - 70)
  client.sk.drawImage("ui/timeslider", knob)
  discard client.sk.drawText("pixelated", $world.tick, knob + vec2(0, 14),
    Yellow, maxWidth = 151, clip = false, hAlign = CenterAlign)
  if client.hit(trackStart - 32, height - 70, trackWidth + 64, 68) and
    client.window.buttonPressed[MouseLeft]:
      client.dragging = true
  if client.dragging:
    let target = int32(clamp((client.mouse.x - trackStart) /
      max(1'f, trackWidth - 87), 0'f, 1'f) * duration)
    client.paused = true
    if client.window.buttonReleased[MouseLeft]:
      client.dragging = false
      client.seek(target)
    else:
      let needsIndex = client.scrubs.points.len == 0 or
        client.scrubs.duration != int32(client.session.tape.hashes.len)
      if needsIndex or
        client.scrubs.requiredTick(target, true) != client.session.world.tick:
          client.seek(target, true)
      else:
        client.pendingSeek = false
  if client.scrubs.points.len > 0 and not client.scrubs.complete():
    client.label("Preparing seek points: " & $(
      client.scrubs.progress() * 100 div max(1'i32, client.scrubs.duration)
    ) & "%", width / 2 - 200, 40)
  if client.message.len > 0:
    client.label(client.message, width / 2 - 200, 12)

proc overHud(client: Client): bool =
  ## Blocks world input under the original panel silhouettes.
  let
    width = client.size.x
    height = client.size.y
  client.hit(0, 0, 350, 330) or
    client.hit(width - 488, 0, 488, 335) or
    client.hit(0, height - 390, 350, 390) or
    client.hit(350, height - 328, 105, 328) or
    client.hit(width - 300, height - 328, 300, 328) or
    client.hit(width - 420, height - 329, 100, 329) or
    (client.selected >= 0 and client.hit((width - 623) / 2,
      height - 373, 623, 310)) or
    client.hit(0, height - 81, width, 81)

proc input(client: Client) =
  ## Handles camera navigation, selection, and keyboard transport.
  let
    window = client.window
    area = client.viewport()
    mouse = client.mouse()
  if window.buttonPressed[KeySpace]:
    client.paused = not client.paused
    client.pendingSeek = false
  if window.buttonPressed[KeyPeriod]:
    client.paused = true
    client.pendingSeek = false
    client.step()
  if window.buttonPressed[KeyM]:
    client.miniature = not client.miniature
  if window.buttonPressed[KeyEscape]:
    client.selected = -1
    client.inspected = -1
    client.follow = false
  if window.buttonPressed[KeyF]:
    client.follow = not client.follow
  if window.buttonPressed[KeyF5]:
    client.saveReplay()
  if client.hit(30, client.size.y - 390, 300, 300) and
    window.buttonDown[MouseLeft]:
      client.center = vec2((Width.float32 - 1) / 2) +
        (mouse - vec2(180, client.size.y - 240)) * ((Width + 10).float32 / 300)
      client.follow = false
  if not client.overHud():
    if window.scrollDelta.y != 0:
      client.zoom = clamp(client.zoom *
        pow(1.0015'f, window.scrollDelta.y), 2'f, 128'f)
    if window.buttonDown[MouseRight]:
      client.center -= window.mouseDelta.vec2 /
        (client.zoom * client.sk.uiScale)
      client.follow = false
    if window.buttonPressed[MouseLeft]:
      let position = (mouse - area / 2) /
        client.zoom + client.center
      let tile = tileAt(int32(floor(position.x)), int32(floor(position.y)))
      client.selected = -1
      if tile >= 0:
        client.inspected = client.session.world.tiles[tile].station
        for i, cog in client.session.world.cogs:
          if cog.tile.distance2(tile) <= 2:
            client.selected = i
            client.inspected = -1
  if client.follow and client.selected >= 0:
    let tile = client.session.world.cogs[client.selected].tile
    client.center = vec2(tile.x.float32, tile.y.float32)

proc renderFrame(client: Client) {.measure.} =
  ## Runs bounded catch-up ticks and renders one independent client frame.
  let
    now = getMonoTime()
    elapsed = min(0.1, (now - client.lastTime).inMicroseconds.float / 1_000_000)
  client.lastTime = now
  client.sk.uiScale = 1
  try:
    client.input()
    if client.scrubs.points.len > 0 and not client.scrubs.complete():
      client.scrubs.extendScrubs()
    if client.pendingSeek and
      client.scrubs.available(client.pendingTarget, client.pendingSnap):
        client.seek(client.pendingTarget, client.pendingSnap)
    if not client.paused:
      let steps =
        when CvcTracePath.len > 0:
          1
        else:
          frameTicks(client.accumulator, elapsed, client.rate)
      for i in 0 ..< steps:
        client.step()
      if client.session.world.tick >= MaxTicks or
        (not client.live and client.session.playback and client.session.world.tick >=
        int32(client.session.tape.hashes.len)):
          client.paused = true
          if client.repeating and client.session.tape.hashes.len > 0:
            client.seek(0)
            client.paused = false
    let canvas = client.window.size
    if canvas.x <= 0 or canvas.y <= 0:
      return
    glViewport(0, 0, canvas.x, canvas.y)
    glDisable(GL_SCISSOR_TEST)
    client.sk.clearScreen(Background)
    client.drawMap()
    client.sk.beginUi(client.window, client.window.size)
    client.drawChrome()
    client.drawInspector()
    client.sk.endUi()
    if client.selected >= 0:
      client.renderer.drawProfile(client.window.size,
        vec2((client.size.x - 623) / 2 + 424, client.size.y - 341),
        client.session.world.cogs[client.selected].role,
        client.session.world.cogs[client.selected].team)
    client.drawMap(true)
    client.sk.beginUi(client.window, client.window.size)
    let
      ratio = 300'f / (Width + 10).float32
      origin = vec2(180, client.size.y - 240) +
        (client.center - vec2((Width.float32 - 1) / 2)) * ratio
      extent = client.size / client.zoom * ratio
      low = max(origin - extent / 2, vec2(30, client.size.y - 390))
      high = min(origin + extent / 2, vec2(330, client.size.y - 90))
    if high.x > low.x and high.y > low.y:
      for edge in [vec4(low.x, low.y, high.x - low.x, 1),
        vec4(low.x, high.y - 1, high.x - low.x, 1),
        vec4(low.x, low.y, 1, high.y - low.y),
        vec4(high.x - 1, low.y, 1, high.y - low.y)]:
          client.sk.drawRect(edge.xy, edge.zw, rgbx(255, 255, 255, 255))
    client.sk.endUi()
    client.window.swapBuffers()
    when defined(emscripten):
      runBrowserScript("window.cvcReplayFrame && window.cvcReplayFrame()")
  except CvcError as error:
    client.paused = true
    client.message = error.msg
    echo error.msg
    when defined(emscripten):
      runBrowserScript("window.cvcReplayError && " &
        "window.cvcReplayError('Replay simulation failed; see console')")

proc runClient*(session: Session, sources: array[CogCount, string],
    recordPath: string, paused = false, speed = 1'i32) =
  ## Opens the native or browser client with identical simulation code.
  let window = newWindow("FourScore", ivec2(1440, 960))
  window.makeContextCurrent()
  loadExtensions()
  let client = Client(
    session: session,
    live: not session.playback,
    policies: newBots(sources),
    paused: paused,
    rate: speed.float64,
    window: window,
    sk: newSilky(window, "data/atlas.png"),
    center: vec2(29, 29),
    zoom: 26,
    selected: -1,
    inspected: -1,
    lastTime: getMonoTime(),
    recordPath: recordPath
  )
  client.sk.uiScale = 1
  client.renderer = newRenderer(client.sk, session.world)
  if session.playback:
    client.scrubs = beginScrubs(session.tape)
    client.lastTime = getMonoTime()
  for i, cog in session.world.cogs:
    client.previous[i] = cog.tile
  when CvcTracePath.len > 0:
    var capturedFrames = 0
  defer:
    when CvcTracePath.len > 0:
      finishCapture(CvcTracePath)
    else:
      finishCapture("out/profile.json")
  window.onFrame = proc() =
    ## Dispatches one frame from the platform event loop.
    when not defined(emscripten):
      if window.buttonPressed[KeyF2]:
        toggleCapture()
    when CvcTracePath.len > 0:
      if capturedFrames == CvcTraceWarmup:
        startCapture()
    client.renderFrame()
    when CvcTracePath.len > 0:
      inc capturedFrames
      if capturedFrames >= CvcTraceWarmup + CvcTraceFrames:
        finishCapture(CvcTracePath)
        echo "Profile tick=", session.world.tick,
          " hash=", session.world.stateHash()
        window.closeRequested = true
  window.onFileDrop = proc(fileName, fileData: string) =
    ## Opens a dropped action replay in read-only mode.
    try:
      client.session = loadBytes(fileData)
      client.accumulator = 0
      client.live = false
      client.paused = true
      client.takeover = false
      client.renderer = newRenderer(client.sk, client.session.world)
      client.scrubs = beginScrubs(client.session.tape)
      client.pendingSeek = false
      client.dragging = false
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
