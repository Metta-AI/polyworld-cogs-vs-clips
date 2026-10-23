import
  std/os,
  pixie, silky/atlas

proc buildAtlas() =
  ## Packs original MettaScope artwork, masks, and pixel font.
  let builder = newAtlasBuilder(8192, 2)
  for folder in ["agents", "objects", "terrain", "ui", "theme",
    "resources", "profiles", "starfield", "minimap", "vibe", "icons/objects"]:
      builder.addDir("data/" & folder, "data/")
  doAssert builder.addImage("selection", readImage("data/selection.png"))
  builder.addFont("data/Inter-Regular.ttf", "Default", 15.0)
  builder.addFont("data/Inter-Regular.ttf", "Title", 22.0)
  builder.addFont("data/pf_tempesta_five_compressed.ttf", "pixelated", 32.0)
  builder.write("data/atlas.png")

setCurrentDir(currentSourcePath().parentDir.parentDir)
buildAtlas()
