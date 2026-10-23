import std/[os, strutils]

const Root = currentSourcePath().parentDir
let dependencyRoot = getEnv("POLYWORLD_DEPS", Root.parentDir)
switch("path", Root / "src")
for line in readFile(Root / "dependencies.lock").splitLines():
  let fields = line.splitWhitespace()
  if fields.len == 0:
    continue
  let directory = dependencyRoot / fields[0]
  switch("path", directory / "src")
  switch("path", directory)
switch("outdir", Root / "out")
switch("nimcache", Root / "out/cache-default")
switch("define", "flatty64")
switch("mm", "arc")
when defined(emscripten):
  switch("os", "linux")
  switch("cpu", "wasm32")
  switch("cc", "clang")
  switch("clang.exe", "emcc")
  switch("clang.linkerexe", "emcc")
  switch("exceptions", "goto")
  switch("define", "noSignalHandler")
  switch("passL", "-sALLOW_MEMORY_GROWTH=1 -sSTACK_SIZE=8388608")
  when not defined(headless):
    switch("passL", "-sASYNCIFY -sFETCH -sUSE_WEBGL2=1 -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1")
    switch("passL", "-sGL_ENABLE_GET_PROC_ADDRESS=1")
    switch("passL", "--preload-file " & Root / "data" & "@data")
    switch("passL", "-sEXPORTED_RUNTIME_METHODS=FS,callMain")
    switch("passL", "-sFORCE_FILESYSTEM=1")
