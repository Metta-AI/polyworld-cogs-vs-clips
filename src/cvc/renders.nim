import
  std/[algorithm, strutils],
  silky, vmath, chroma,
  sims, colors, grounds, tilemaps, pixelators, pipes, shaderquads, starfields,
  scrubs, tracks, motions, bars

const
  Roles* = ["agent", "miner", "aligner", "scrambler", "scout"]

type
  Renderer* = ref object
    motion*: Motion
    px, mini: Pixelator
    zones: array[TeamCount, TileMap]
    owners: seq[Owner]
    selected: int
    tick: int32
    terrainSeed: int32
    fogs: array[2, TileMap]
    explored: Exploration
    tracks: Tracks
    gridQuad: ShaderQuad

proc stationSprite*(station: Station): string =
  ## Resolves the fixed game's original MettaScope object asset.
  case station.kind
  of Hub: "hub"
  of Junction:
    if station.owner == Neutral: "junction" else: "junction.working"
  of Ship: "ship"
  of Extractor: ($station.element).toLowerAscii & "_extractor"
  of Gear: Roles[ord(station.role)]

proc observe*(renderer: Renderer, world: World) {.measure.} =
  ## Accumulates bounded exploration from live ticks, never replay snapshots.
  renderer.motion.observe(world)
  renderer.tracks.observeTracks(world)
  updatePipegridState(world)
  renderer.explored.observeExploration(world)

proc reset*(renderer: Renderer, world: World) =
  ## Clears presentation history before reconstructing recorded input.
  resetPipegridState()
  renderer.explored = default(typeof(renderer.explored))
  renderer.tracks = default(Tracks)
  renderer.observe(world)
  renderer.motion.reset(world)

proc restore*(renderer: Renderer, point: ScrubPoint) =
  ## Restores fog and pipe history from a seek checkpoint.
  renderer.motion.reset(point.world)
  renderer.explored = point.explored
  renderer.tracks = point.tracks
  restorePipes(point.pipes)
  renderer.owners.setLen(0)

proc newRenderer*(sk: Silky, world: World): Renderer =
  ## Initializes copied MettaScope GPU renderers from the live world.
  result = Renderer(selected: -2, tick: -1, terrainSeed: world.seed)
  initGrounds(world, sk)
  result.px = newPixelator(sk)
  result.mini = newPixelator(sk)
  for i in 0 ..< TeamCount:
    result.zones[i] = newTileMap(Width, Height, 64, "data/aoe7x8.png")
    for tile in 0 ..< TileCount:
      result.zones[i].indexData[tile] = 49
    result.zones[i].setupGPU()
  result.gridQuad = newGridQuad("data/view/grid10.png", 10, 10)
  for i in 0 ..< 2:
    result.fogs[i] = newTileMap(Width, Height, 64, "data/fog7x8.png")
    result.fogs[i].setupGPU()
  result.reset(world)

proc refresh*(renderer: Renderer, world: World, inspected: int) {.measure.} =
  ## Rebuilds original AoE tile maps when ownership or selection changes.
  var changed = renderer.owners.len != world.stations.len or
    renderer.selected != inspected
  if not changed:
    for i, station in world.stations:
      if renderer.owners[i] != station.owner:
        changed = true
        break
  if not changed:
    return
  renderer.selected = inspected
  renderer.owners.setLen(world.stations.len)
  for i, station in world.stations:
    renderer.owners[i] = station.owner
  var coverage: array[TileCount, Owner]
  for tile in 0'i32 ..< TileCount:
    if inspected >= 0 and
      world.stations[inspected].kind in {Hub, Junction, Ship}:
        let
          station = world.stations[inspected]
          radius = if station.kind == Hub: HubRadius else: TerritoryRadius
        if tile.distance2(station.tile) < radius * radius:
          coverage[tile] = station.owner
    else:
      coverage[tile] = world.territory(tile)
  const Offsets = [(-1'i32, -1'i32), (0'i32, -1'i32), (1'i32, -1'i32),
    (1'i32, 0'i32), (1'i32, 1'i32), (0'i32, 1'i32),
    (-1'i32, 1'i32), (-1'i32, 0'i32)]
  for i, team in Teams:
    for tile in 0'i32 ..< TileCount:
      var index = 49
      if coverage[tile] == team:
        var pattern = 0
        for j, offset in Offsets:
          let other = tileAt(tile.x + offset[0], tile.y + offset[1])
          if other < 0 or coverage[other] != team:
            pattern = pattern or (1 shl j)
        index = grounds.patternToTile[pattern]
      renderer.zones[i].indexData[tile] = uint8(index)
    renderer.zones[i].updateGPU()

proc drawFog(renderer: Renderer, world: World, selected: int,
    mvp: Mat4, historical: bool) {.measure.} =
  ## Uses the original fog edge atlas over bounded live visibility data.
  let layer = renderer.fogs[ord(historical)]
  var visible: array[TileCount, bool]
  for tile in 0 ..< TileCount:
    for i in 0 ..< CogCount:
      if selected >= 0 and i != selected:
        continue
      if (historical and renderer.explored[i][tile]) or
        (not historical and world.visible(i, int32(tile))):
          visible[tile] = true
  const Offsets = [(-1'i32, -1'i32), (0'i32, -1'i32), (1'i32, -1'i32),
    (1'i32, 0'i32), (1'i32, 1'i32), (0'i32, 1'i32),
    (-1'i32, 1'i32), (-1'i32, 0'i32)]
  for tile in 0'i32 ..< TileCount:
    var index = 49
    if visible[tile]:
      var pattern = 0
      for j, offset in Offsets:
        let other = tileAt(tile.x + offset[0], tile.y + offset[1])
        if other >= 0 and not visible[other]:
          pattern = pattern or (1 shl j)
      index = grounds.patternToTile[pattern]
    layer.indexData[tile] = uint8(index)
  layer.updateGPU()
  layer.draw(mvp, 2'f, 1.5'f,
    color(0, 0, 0, if historical: 1'f else: 0.5'f))

proc drawWorld*(renderer: Renderer, world: World,
    previous: array[CogCount, int32], fraction: float32,
    selected, inspected: int, canvas: IVec2, area: Vec4,
    center: Vec2, zoom: float32, miniature = false,
    grid = false, vision = false, fog = false, speed = 1'f) {.measure.} =
  ## Executes MettaScope terrain, AoE, pipe, and masked sprite passes.
  grounds.canvasSize = canvas
  renderer.refresh(world, inspected)
  let
    projection = ortho(0'f, canvas.x.float32, canvas.y.float32, 0'f, -1'f, 1'f)
    view = translate(vec3(area.x + area.z / 2, area.y + area.w / 2, 0)) *
      scale(vec3(zoom, zoom, 1)) * translate(vec3(-center.x, -center.y, 0))
    mvp = projection * view
    pixels = mvp * scale(vec3(1'f / 128, 1'f / 128, 1))
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  glEnable(GL_SCISSOR_TEST)
  glScissor(area.x.GLint, (canvas.y.float32 - area.y - area.w).GLint,
    area.z.GLsizei, area.w.GLsizei)
  drawStarfield(canvas, area, center, world.tick)
  grounds.drawTerrain(mvp, renderer.px, renderer.mini)
  grounds.drawMaskedSplatComposite(mvp, renderer.px)
  for i in 0 ..< TeamCount:
    renderer.zones[i].draw(mvp, 2'f, 1.5'f, getTeamColor(i + 1).color)
  if miniature:
    drawMinimapPipePips(renderer.mini)
    for i, station in world.stations:
      if station.kind == Extractor and station.stock <= 0:
        continue
      var name = "minimap/" & station.stationSprite()
      if name notin renderer.mini:
        name = "minimap/unknown"
      renderer.mini.drawSprite(name,
        ivec2(station.tile.x, station.tile.y) * 16,
        if station.kind == Junction:
          if station.owner == Neutral: DarkGray
          else: getTeamColor(ord(station.owner))
        else: rgbx(255, 255, 255, 255))
    for i, cog in world.cogs:
      renderer.mini.drawSprite("minimap/agent",
        ivec2(cog.tile.x, cog.tile.y) * 16, getTeamColor(ord(cog.team)))
      if i == selected:
        renderer.mini.drawSprite("minimap/selection",
          ivec2(cog.tile.x, cog.tile.y) * 16)
    renderer.mini.flush(mvp * scale(vec3(1'f / 16, 1'f / 16, 1)))
  else:
    if selected >= 0:
      for i in 0 ..< renderer.tracks.counts[selected]:
        let
          track = renderer.tracks.marks[selected][i]
          age = world.tick - track.tick
        if age >= 0 and age < TrackLifetime:
          let alpha = uint8(255 * (TrackLifetime - age) div TrackLifetime)
          renderer.px.drawSprite(
            track.sprite(),
            ivec2(track.tile.x, track.tile.y) * 128,
            rgbx(255, 255, 255, alpha)
          )
    drawPipegrids(renderer.px)
    var objects: seq[tuple[y: float32, kind, id: int, position: Vec2]]
    for i, station in world.stations:
      if station.kind == Extractor and station.stock <= 0:
        continue
      objects.add((station.tile.y.float32, 0, i,
        vec2(station.tile.x.float32, station.tile.y.float32)))
    for i, cog in world.cogs:
      let
        position = renderer.motion.position(i, fraction, speed)
      objects.add((position.y, 1, i, position))
    objects.sort(proc(a, b: typeof(objects[0])): int =
      ## Applies the original painter order with stable identity ties.
      result = cmp(a.y, b.y)
      if result == 0:
        result = cmp(a.kind, b.kind)
      if result == 0:
        result = cmp(a.id, b.id)
    )
    for item in objects:
      let pos = (item.position * 128 + vec2(0, -32)).ivec2
      if item.kind == 1:
        let
          cog = world.cogs[item.id]
          name = "agents/" & Roles[ord(cog.role)] & "." &
            renderer.motion.direction(item.id, fraction, speed)
        renderer.px.drawSprite(name, pos, getTeamColor(ord(cog.team)),
          name & ".mask")
        for bar, values in [(cog.hp, cog.role.maxHp),
          (cog.energy, cog.role.maxEnergy)]:
            let
              width = if bar == 0: 6 else: 4
              sprite = if bar == 0: "agents/barPip5x6"
                else: "agents/barPip3x4"
              base = (item.position * 128).ivec2
            for pip in 0 ..< 10:
              let point = base + ivec2(int32((pip - 5) * width + width div 2),
                int32(-68 + bar * 7))
              renderer.px.drawSprite(sprite & "Bg", point)
              let previous = renderer.motion.previous[item.id]
              let changed = changedPip(
                values[0],
                if bar == 0: previous.hp else: previous.energy,
                values[1], 10, pip
              )
              if changed or pip < values[0] * 10 div max(1'i32, values[1]):
                renderer.px.drawSprite(sprite, point,
                  if changed: rgbx(255, 255, 255, 255)
                  elif bar == 0: getTeamColor(ord(cog.team)) else: Yellow)
        if grid:
          let
            text = "COG " & $(item.id + 1)
            size = renderer.px.textSize("pixelated", text)
            base = (item.position * 128).ivec2
          renderer.px.drawText("pixelated", text,
            base - ivec2(size.x.int32 div 2, 80 + size.y.int32), Yellow)
        if item.id == selected:
          renderer.px.drawSprite("selection", (item.position * 128).ivec2)
      else:
        let
          station = world.stations[item.id]
          name = "objects/" & station.stationSprite()
        if item.id == inspected:
          renderer.px.drawSprite("selection", (item.position * 128).ivec2)
        if station.kind == Junction and station.owner != Neutral:
          renderer.px.drawSprite(name, pos,
            getTeamColor(ord(station.owner)), lamp = "objects/junction.lamp")
        else:
          if name & ".mask" in renderer.px:
            renderer.px.drawSprite(name, pos,
              getTeamColor(ord(station.owner)), name & ".mask")
          else:
            renderer.px.drawSprite(name, pos)
    renderer.px.flush(pixels)
  if vision:
    renderer.drawFog(world, selected, mvp, false)
  if fog:
    renderer.drawFog(world, selected, mvp, true)
  if grid:
    renderer.gridQuad.draw(mvp, vec2(Width.float32, Height.float32),
      vec2(1), vec4(1), 1'f)
  glDisable(GL_SCISSOR_TEST)

proc drawProfile*(renderer: Renderer, canvas: IVec2,
    position: Vec2, role: Role, team: Owner) =
  ## Draws the selected portrait with the original selective tint shader.
  let
    name = "profiles/" & Roles[ord(role)]
    projection = ortho(0'f, canvas.x.float32, canvas.y.float32, 0'f, -1'f, 1'f)
    size = renderer.px.spriteSize(name).vec2
    matrix = projection * translate(vec3(position.x, position.y, 0))
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
  renderer.px.drawSprite(name, (size / 2).ivec2,
    getTeamColor(ord(team)), name & ".mask")
  renderer.px.flush(matrix)

proc drawStationProfile*(renderer: Renderer, canvas: IVec2,
    position: Vec2, station: Station) =
  ## Draws the original building portrait when that asset exists.
  let
    key = if station.kind == Junction: "junction" else: station.stationSprite()
    name = "profiles/" & key
  if name notin renderer.px:
    return
  let
    projection = ortho(0'f, canvas.x.float32, canvas.y.float32, 0'f, -1'f, 1'f)
    size = renderer.px.spriteSize(name).vec2
    matrix = projection * translate(vec3(position.x, position.y, 0))
    mask = if name & ".mask" in renderer.px: name & ".mask" else: ""
  renderer.px.drawSprite(name, (size / 2).ivec2,
    if mask.len > 0: getTeamColor(ord(station.owner))
    else: rgbx(255, 255, 255, 255), mask)
  renderer.px.flush(matrix)
