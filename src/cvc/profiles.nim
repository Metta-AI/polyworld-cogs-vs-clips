import
  std/os,
  fluffy/measure

when not defined(emscripten):
  import std/osproc

export measure

const
  CvcTracePath* {.strdefine.} = ""
  CvcTraceWarmup* {.intdefine.} = 1000
  CvcTraceFrames* {.intdefine.} = 100
  FluffySource = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "fluffy/src/fluffy.nim"

var tracing = false

proc startCapture*() =
  ## Starts a bounded Fluffy capture at a frame boundary.
  startTrace()
  tracing = true

proc finishCapture*(path: string, openViewer = false) =
  ## Saves at most 10,000 events and optionally launches Fluffy.
  if not tracing:
    return
  endTrace()
  tracing = false
  let directory = path.parentDir
  if directory.len > 0:
    createDir(directory)
  dumpMeasures(path)
  when not defined(emscripten):
    if openViewer:
      let viewer = startProcess(
        "nim",
        workingDir = FluffySource.parentDir.parentDir,
        args = @["r", "-d:release", FluffySource, absolutePath(path)],
        options = {poUsePath, poParentStreams}
      )
      viewer.close()

proc toggleCapture*() =
  ## Starts recording or saves and opens the interactive F2 capture.
  if tracing:
    finishCapture("out/profile.json", true)
  else:
    startCapture()
