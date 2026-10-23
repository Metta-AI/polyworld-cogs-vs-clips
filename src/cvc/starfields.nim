import
  std/os,
  opengl, silky, silky/drawers/ogl, shady, vmath, pixie, windy,
  common

## Starfield and cloud background layers.
## The starfield is a static fullscreen image that always fills the viewport
## maintaining its aspect ratio (cover mode). The clouds layer is drawn
## slightly larger and offset based on camera position for a parallax effect.

type
  BackgroundLayer = object
    texture: GLuint
    texW: float32
    texH: float32

const
  ParallaxStarsStrength* = 0.08f
  ParallaxCloudsStrength* = 0.32f
  ParallaxMotionSpeed* = 1.0f

var
  # Shader uniforms for the fullscreen textured quad.
  starfieldScreenSize: Uniform[Vec2]
  starfieldTexSize: Uniform[Vec2]
  starfieldOffset: Uniform[Vec2]
  starfieldScale: Uniform[float32]
  starfieldTex: Uniform[Sampler2D]
  starfieldShader: Shader
  starfieldVao: GLuint
  bgStarfield: BackgroundLayer
  bgClouds: BackgroundLayer
  starfieldInitialized: bool = false

proc starfieldVert(fragUV: var Vec2) =
  ## Fullscreen quad vertex shader. Generates corners from gl_VertexID.
  let corner = ivec2(gl_VertexID mod 2, gl_VertexID div 2)
  fragUV = vec2(float(corner.x), float(corner.y))
  gl_Position = vec4(fragUV.x * 2.0 - 1.0, 1.0 - fragUV.y * 2.0, 0.0, 1.0)

proc starfieldFrag(fragUV: Vec2, FragColor: var Vec4) =
  ## Textured quad fragment shader with aspect-correct cover mapping,
  ## optional scale and parallax offset.
  let
    sa = starfieldScreenSize.x / starfieldScreenSize.y
    ta = starfieldTexSize.x / starfieldTexSize.y
    ratio = sa / ta
    # Cover mapping: scale UVs so the image fills the screen, cropping the excess.
    uCov = min(ratio, 1.0)
    vCov = min(1.0 / ratio, 1.0)
  var
    u = fragUV.x * uCov + (1.0 - uCov) * 0.5
    v = fragUV.y * vCov + (1.0 - vCov) * 0.5

  # Apply scale (>1.0 zooms in, showing less of the texture) and parallax offset.
  u = (u - 0.5) / starfieldScale + 0.5 + starfieldOffset.x
  v = (v - 0.5) / starfieldScale + 0.5 + starfieldOffset.y

  FragColor = texture(starfieldTex, vec2(u, v))

proc loadLayer(imagePath: string): BackgroundLayer {.measure.} =
  ## Load an image as a background layer texture.
  let image = readImage(imagePath)
  result.texW = image.width.float32
  result.texH = image.height.float32

  glGenTextures(1, result.texture.addr)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, result.texture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
    image.width.GLint, image.height.GLint, 0,
    GL_RGBA, GL_UNSIGNED_BYTE,
    cast[pointer](image.data[0].addr)
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

proc initStarfield() =
  ## Initialize the shared shader, VAO, and load both layer textures.
  when defined(emscripten):
    starfieldShader = newShader(
      ("starfieldVert", toGLSL(starfieldVert, glslES3)),
      ("starfieldFrag", toGLSL(starfieldFrag, glslES3))
    )
  else:
    starfieldShader = newShader(
      ("starfieldVert", toGLSL(starfieldVert, glslDesktop)),
      ("starfieldFrag", toGLSL(starfieldFrag, glslDesktop))
    )

  # Empty VAO; vertices are generated from gl_VertexID.
  glGenVertexArrays(1, starfieldVao.addr)

  bgStarfield = loadLayer("data" / "starfield/starfield.png")
  bgClouds = loadLayer("data" / "starfield/clouds.png")

  starfieldInitialized = true

proc drawLayer(layer: BackgroundLayer, screenSize: Vec2, offset: Vec2, scale: float32) =
  ## Draw a single background layer as a fullscreen quad.
  glUseProgram(starfieldShader.programId)
  starfieldShader.setUniform("starfieldScreenSize", screenSize)
  starfieldShader.setUniform("starfieldTexSize", vec2(layer.texW, layer.texH))
  starfieldShader.setUniform("starfieldOffset", offset)
  starfieldShader.setUniform("starfieldScale", scale)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, layer.texture)
  starfieldShader.setUniform("starfieldTex", 0)
  starfieldShader.bindUniforms()

  glBindVertexArray(starfieldVao)
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)
  glBindVertexArray(0)
  glUseProgram(0)

proc drawStarfield*(canvas: IVec2, area: Vec4, center: Vec2, tick: int32) =
  ## Draws original parallax layers from live camera and simulation time.
  if not starfieldInitialized:
    initStarfield()
  var previous: array[4, GLint]
  glGetIntegerv(GL_VIEWPORT, previous[0].addr)
  glViewport(area.x.GLint, (canvas.y.float32 - area.y - area.w).GLint,
    area.z.GLsizei, area.w.GLsizei)
  let
    screenSize = vec2(area.z, area.w)
    base = center / vec2(Width.float32, Height.float32) - vec2(0.5)
    drift = vec2(tick.float32 * 0.0005'f * ParallaxMotionSpeed)
  drawLayer(bgStarfield, screenSize,
    (base + drift) * ParallaxStarsStrength, 1'f)
  drawLayer(bgClouds, screenSize,
    (base + drift) * ParallaxCloudsStrength, 0.6'f)
  glViewport(previous[0], previous[1], previous[2], previous[3])
