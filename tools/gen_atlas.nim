import
  std/os,
  pixie, silky/atlas

proc buildAtlas() =
  ## Packs original artwork and a mask-composited cliff overlay.
  let builder = newAtlasBuilder(8192, 2)
  for folder in ["agents", "objects", "terrain", "ui", "theme",
    "resources", "profiles", "starfield"]:
      builder.addDir("data/" & folder, "data/")
  let frame = readImage("data/ui/panel_center.png").subImage(0, 0, 396, 320)
  doAssert builder.addImage("hud/frame", frame)
  let
    cliffs = readImage("data/terrain/blob7x8.png")
    mask = readImage("data/terrain/mask7x8.png")
  for i in 0 ..< cliffs.data.len:
    let
      opacity = 255 - uint32(mask.data[i].r)
      pixel = cliffs.data[i]
    cliffs.data[i] = rgbx(
      uint8(uint32(pixel.r) * opacity div 255),
      uint8(uint32(pixel.g) * opacity div 255),
      uint8(uint32(pixel.b) * opacity div 255),
      uint8(opacity)
    )
  doAssert builder.addImage("terrain/cliffs", cliffs)
  doAssert builder.addImage("selection", readImage("data/selection.png"))
  builder.addFont("data/Inter-Regular.ttf", "Default", 15.0)
  builder.addFont("data/Inter-Regular.ttf", "Title", 22.0)
  builder.write("data/atlas.png")

setCurrentDir(currentSourcePath().parentDir.parentDir)
buildAtlas()
