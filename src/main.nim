# Out of Phase
# Puzzle platformer about sound and music, eaching synthesiser mechanics.


# Simple oscillators
# add and multiply waves
# doors/machines require an input waveform to match a certain pattern 

# CONTROLS
# Left Right
# A = Jump
# B = open connection menu
  # arrows to choose connection
  # B = select

import nico
import util
import strutils
import math
import sequtils
import pool
import vec
import sndfile

{.this:self.}

const BUFFERSIZE = 1024

## TYPES

type Hitbox = tuple
  x,y,w,h: int

type Object = ref object of RootObj
  name: string
  x,y: int
  hitbox: Hitbox

type
  Socket = ref object of RootObj
    x,y: int
    obj: Object
    value: float32
    connectedTo: Socket

  Box = ref object of Object
    buffer: array[BUFFERSIZE, float32]
    writeHead: int
    value: float32
    distanceFromPlayer: float
    inputSockets: seq[Socket]
    outputSockets: seq[Socket]

  Cable = ref object of RootObj
    toRemove: bool
    a: Socket
    b: Socket
    points: array[3, tuple[pos: Vec2f, vel: Vec2f]]
    color: int

type Player = ref object of Object
  xv,yv: float
  dir: int
  remx,remy: float
  wasOnGround: bool
  wasOnWall: bool
  jump: bool
  fallThrough: bool
  socket: Socket
  connectedToInput: bool
  nearestBox: Box
  nearestBoxDist: float
  walkFrame: int

type OscShape = enum
  oscSine = "sin"
  oscSquare = "square"
  oscTriangle = "tri"
  oscSaw = "saw"
  oscPulse = "pulse"

type OscBox = ref object of Box
  freq: float32
  phase: float32
  shape: OscShape
  pulseWidth: float32
  phaseMod: float32
  hasPhaseMod: bool

type TargetBox = ref object of Box
  # takes a bunch of hidden inputs that say what the output should be
  targetInputs: seq[Socket]
  targetBuffer: array[BUFFERSIZE, float32]
  differenceBuffer: array[BUFFERSIZE, float32]
  targetValue: float32
  difference: float32

type AlterKind = enum
  akAdd = "add"
  akMul = "mul"
  akInvert = "inv"
  akDiv2 = "half"

type FilterKind = enum
  fkLP = "LP"
  fkHP = "HP"

type AlterBox = ref object of Box
  kind: AlterKind
  inputBuffer0: array[BUFFERSIZE, float32]
  inputBuffer1: array[BUFFERSIZE, float32]

type SplitterBox = ref object of Box

type FilterBox = ref object of Box
  kind: FilterKind
  cutoff: float32
  q: float32
  a0,a1,a2,b1,b2: float
  z1,z2: float

type ParticleKind = enum
  dustParticle
  sparkParticle

type Particle = object
  kind: ParticleKind
  pos: Vec2f
  vel: Vec2f
  ttl: float
  maxttl: float
  above: bool

type SfxData = ref object
  data: seq[float32]

type SfxChannel = object
  sfx: SfxData
  pos: int

const
  SFX_PLUGIN = 0
  SFX_PLUGOUT = 1
  SFX_JUMP = 2
  SFX_LAND = 3
  SFX_SOLVED = 4
  SFX_UNSOLVED = 5
  SFX_DOOROPEN = 6
  SFX_STEP = 7
  SFX_MONITORON = 8
  SFX_MONITOROFF = 9

## GLOBALS

var gameComplete = false
var gameoverTimeout = 5.0
var frame = 0
var levelId: int
var startX,startY: int
var sampleRate: float32 = 44100.0
var invSampleRate: float32 = 1.0/sampleRate
var player: Player
var objects: seq[Object]
var hiddenObjects: seq[Object]
var cables: seq[Cable]
var timerem: int
var ambience: ptr TSNDFILE
var monitor: bool
var transitionIn: float
var transitionOut: float
var transition: bool

var showMenu: bool
var menuOption = 0
var waveVolume: float32 = 1.0
var sfxVolume: float32 = 1.0
var ambienceVolume: float32 = 0.5
var volumeDisplayTimer: float = 0.0

var noclip: bool

var particles: Pool[Particle]
var sfxLibrary: array[64, SfxData]
var sfxChannels: array[4, SfxChannel]

## PROCS

proc playSound(index: int, channel: int) =
  sfxChannels[channel].sfx = sfxLibrary[index]
  sfxChannels[channel].pos = 0

proc loadLevel(newlevelId: int)
proc isSolid(self: Object, ox,oy: int): bool
proc isSolid(t: uint8): bool

proc newSocket(obj: Object, x,y: int): Socket =
  result = new(Socket)
  result.obj = obj
  result.x = x
  result.y = y

proc newCable(a: Socket, b: Socket): Cable =
  result = new(Cable)
  result.a = a
  result.b = b
  result.color = 8

  let ap = vec2f(a.x.float, a.y.float)
  let bp = vec2f(b.x.float, b.y.float)

  for i in 0..2:
    result.points[i].pos = lerp(ap,bp, (i+1).float / 5.0)
    result.points[i].vel = vec2f(0.0, 0.01)

proc connect(insock: Socket, outsock: Socket, cable = true) =
  if insock.obj == outsock.obj:
    return
  insock.connectedTo = outsock
  outsock.connectedTo = insock
  if cable:
    cables.add(newCable(insock, outsock))

proc disconnect(outsock: Socket) =
  if outsock.connectedTo != nil:
    let tmp = outsock.connectedTo
    outsock.connectedTo = nil
    disconnect(tmp)
  outsock.connectedTo = nil
  for cable in cables:
    if cable.a == outsock or cable.b == outsock:
      cable.toRemove = true

proc disconnect(insock: Socket, outsock: Socket) =
  insock.connectedTo = nil
  outsock.connectedTo = nil
  for cable in cables:
    if cable.a == insock and cable.b == outsock:
      cable.toRemove = true

method process(self: Box) {.base.} =
  buffer[writeHead] = value
  writeHead += 1
  if writeHead == buffer.len:
    writeHead = 0

  if outputSockets.len > 0 and outputSockets[0] != nil:
    outputSockets[0].value = value

method process(self: TargetBox) =
  if targetInputs[0] != nil and targetInputs[0].connectedTo != nil:
    targetValue = targetInputs[0].connectedTo.value
  else:
    value = 0.0

  if inputSockets[0] != nil and inputSockets[0].connectedTo != nil:
    value = inputSockets[0].connectedTo.value
  else:
    value = 0.0


  buffer[writeHead] = value
  targetBuffer[writeHead] = targetValue
  differenceBuffer[writeHead] = targetValue - value

  writeHead += 1
  if writeHead == buffer.len:
    writeHead = 0


proc saturate(input: float, limit: float): float =
  let x1 = abs(input + limit)
  let x2 = abs(input - limit)
  return 0.5 * (x1 - x2)

method process(self: FilterBox) =
  var inA: float32 = 0.0

  if inputSockets[0].connectedTo != nil:
    inA = inputSockets[0].connectedTo.value

  var norm: float
  let K = tan(PI * cutoff)

  case kind:
  of fkLP:
    norm = 1.0 / (1.0 + K / q + K * K)
    a0 = K * K * norm
    a1 = 2.0 * a0
    a2 = a0
    b1 = 2.0 * (K * K - 1.0) * norm
    b2 = (1.0 - K / q + K * K) * norm
  of fkHP:
    norm = 1.0 / (1.0 + K / q + K * K)
    a0 = 1.0 * norm
    a1 = -2.0 * a0
    a2 = a0
    b1 = 2.0 * (K * K - 1.0) * norm
    b2 = (1.0 - K / q + K * K) * norm

  value = inA * a0 + z1
  z1 = inA * a1 + z2 - b1 * value
  z2 = inA * a2 - b2 * value

  procCall process(Box(self))

method process(self: SplitterBox) =
  value = 0.0
  if inputSockets[0].connectedTo != nil:
    value = inputSockets[0].connectedTo.value

  outputSockets[0].value = value
  outputSockets[1].value = value

  procCall process(Box(self))

method process(self: AlterBox) =
  var inA: float32 = 0.0
  var inB: float32 = 0.0

  if inputSockets[0].connectedTo != nil:
    inA = inputSockets[0].connectedTo.value

  if inputSockets.len > 1:
    if inputSockets[1].connectedTo != nil:
      inB = inputSockets[1].connectedTo.value

  inputBuffer0[writeHead] = inA
  inputBuffer1[writeHead] = inB

  case kind:
  of akAdd:
    value = inA + inB
  of akMul:
    value = inA * inB
  of akInvert:
    value = -inA
  of akDiv2:
    value = inA / 2.0
  procCall process(Box(self))

method process(self: OscBox) =
  if hasPhaseMod:
    phaseMod = 0.0
    if inputSockets[0].connectedTo != nil:
      phaseMod = inputSockets[0].connectedTo.value

  case shape:
  of oscSine:
    value = sin(phase + phaseMod)
  of oscSquare:
    value = if phase < PI: -1.0 else: 1.0
  of oscTriangle:
    value = abs(phase / TAU * 2.0 - 1.0) * 2.0 - 1.0
  of oscSaw:
    value = ((phase - PI) / PI)
  of oscPulse:
    value = if phase < TAU * 0.125: -1.0 else: 1.0

  phase += freq * invSampleRate * TAU
  phase = phase mod TAU

  procCall process(Box(self))

proc update(self: Cable, dt: float) =
  let ap = vec2f(a.x.float,a.y.float)
  let bp = vec2f(b.x.float,b.y.float)

  let totalDist = (ap - bp).length

  if totalDist < 2.0:
    return

  const k = 0.2
  const b = 0.5

  for i in 0..2:

    var startPos: Vec2f
    var endPos: Vec2f

    if i == 0:
      startPos = ap
    else:
      startPos = points[i-1].pos

    if i == 2:
      endPos = bp
    else:
      endPos = points[i+1].pos

    var force = vec2f(0.0,0.15)
    # spring towards start and end
    let adiff = (points[i].pos - startPos)
    let ad = adiff.length
    let bdiff = (points[i].pos - endPos)
    let bd = bdiff.length
    if ad > 0.5:
      force += -k * (ad - totalDist / 5.0) * adiff.normalize() - b * points[i].vel
    if bd > 0.5:
      force += -k * (bd - totalDist / 5.0) * bdiff.normalize() - b * points[i].vel
    points[i].vel += force

    points[i].pos += points[i].vel

proc line(a,b: Vec2f) =
  line(a.x, a.y, b.x, b.y)

proc draw(self: Cable) =
  # shadow
  let offset = vec2f(0.0,1.0)
  setColor(1)

  line(a.x, a.y, points[0].pos.x, points[0].pos.y+1)
  line(points[0].pos+offset, points[1].pos+offset)
  line(points[1].pos+offset, points[2].pos+offset)
  line(points[2].pos.x, points[2].pos.y+1, b.x, b.y+1)

  setColor(self.color)
  line(a.x, a.y, points[0].pos.x, points[0].pos.y)
  line(points[0].pos, points[1].pos)
  line(points[1].pos, points[2].pos)
  line(points[2].pos.x, points[2].pos.y, b.x, b.y)

  circfill(a.x,a.y,1)
  circfill(b.x,b.y,1)

method update(self: Object, dt: float) {.base.} =
  discard

method draw(self: Object) {.base.} =
  discard

method draw(self: Box) =
  for socket in outputSockets:
    setColor(13)
    rectfill(socket.x-1, socket.y-1, socket.x+1, socket.y+1)
    if socket.connectedTo == nil:
      setColor(0)
      circfill(socket.x, socket.y, 1)
  for socket in inputSockets:
    setColor(11)
    rectfill(socket.x-1, socket.y-1, socket.x+1, socket.y+1)
    #circfill(socket.x, socket.y, 2)
    if socket.connectedTo == nil:
      setColor(0)
      circfill(socket.x, socket.y, 1)

method drawOsc(self: Box, x,y,w,h: int) {.base.} =
  setColor(0)
  rectfill(x,y,x+w-1,y+h-1)
  setColor(13)
  let hh = h div 2
  for i in 1..<buffer.len:
    let x0 = x + (((i-1).float / buffer.len.float) * w.float).int
    let x1 = x + ((i.float / buffer.len.float) * w.float).int
    let v0 = buffer[(writeHead + (i - 1)) mod buffer.len]
    let v1 = buffer[(writeHead + i) mod buffer.len]
    let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
    let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
    line(x0, y + y0, x1, y + y1)

method drawOsc(self: AlterBox, x,y,w,h: int) =
  setColor(0)
  rectfill(x,y,x+w-1,y+h-1)

  block:
    setColor(11)
    let hh = h div 2
    for i in 1..<buffer.len:
      let x0 = x + (((i-1).float / buffer.len.float) * w.float).int
      let x1 = x + ((i.float / buffer.len.float) * w.float).int
      let v0 = inputBuffer0[(writeHead + (i - 1)) mod buffer.len]
      let v1 = inputBuffer0[(writeHead + i) mod buffer.len]
      let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
      let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
      line(x0, y + y0, x1, y + y1)

  if inputSockets.len > 1:
    setColor(10)
    let hh = h div 2
    for i in 1..<buffer.len:
      let x0 = x + (((i-1).float / buffer.len.float) * w.float).int
      let x1 = x + ((i.float / buffer.len.float) * w.float).int
      let v0 = inputBuffer1[(writeHead + (i - 1)) mod buffer.len]
      let v1 = inputBuffer1[(writeHead + i) mod buffer.len]
      let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
      let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
      line(x0, y + y0, x1, y + y1)

  setColor(13)
  let hh = h div 2
  for i in 1..<buffer.len:
    let x0 = x + (((i-1).float / buffer.len.float) * w.float).int
    let x1 = x + ((i.float / buffer.len.float) * w.float).int
    let v0 = buffer[(writeHead + (i - 1)) mod buffer.len]
    let v1 = buffer[(writeHead + i) mod buffer.len]
    let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
    let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
    line(x0, y + y0, x1, y + y1)

method drawOsc(self: TargetBox, x,y,w,h: int) =
  setColor(0)
  rectfill(x,y,x+w-1,y+h-1)
  let hh = h div 2
  setColor(3)
  for i in 1..<buffer.len:
    let x0 = x + (((i-1).float / buffer.len.float) * w.float).int
    let x1 = x + ((i.float / buffer.len.float) * w.float).int
    let v0 = buffer[(writeHead + (i - 1)) mod buffer.len]
    let v1 = buffer[(writeHead + i) mod buffer.len]
    let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
    let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
    line(x0, y + y0, x1, y + y1)

  setColor(if difference < 0.1: 8 else: 6)
  for i in 1..<targetBuffer.len:
    let x0 = x + (((i-1).float / targetBuffer.len.float) * w.float).int
    let x1 = x + ((i.float / targetBuffer.len.float) * w.float).int
    let v0 = targetBuffer[(writeHead + (i - 1)) mod targetBuffer.len]
    let v1 = targetBuffer[(writeHead + i) mod targetBuffer.len]
    let y0 = hh - clamp((v0 * hh.float).int, -hh + 2, hh - 2)
    let y1 = hh - clamp((v1 * hh.float).int, -hh + 2, hh - 2)
    line(x0, y + y0, x1, y + y1)

  let bucketSize = differenceBuffer.len div w
  for x0 in 0..<w:
    var bucketDifference = 0.0
    for i in 0..<bucketSize:
      bucketDifference += abs(differenceBuffer[x0 * bucketSize + i])
    if bucketDifference / bucketSize.float > 0.05:
      pset(x + x0, y+h+1, 6)
    else:
      pset(x + x0, y+h+1, 8)

method draw(self: OscBox) =
  drawOsc(x+2,y+2,12,10)
  procCall draw(Box(self))

method draw(self: TargetBox) =
  drawOsc(x+2,y+2,12,10)
  procCall draw(Box(self))

method update(self: Box, dt: float) =
  let dx = (self.x + 8).float - (player.x + 8).float
  let dy = (self.y + 8).float - (player.y + 8).float
  distanceFromPlayer = sqrt(dx * dx + dy * dy)

method update(self: TargetBox, dt: float) =

  var currentDifference = 0.0

  let bucketSize = differenceBuffer.len div 128
  for x0 in 0..<128:
    var bucketDifference = 0.0
    for i in 0..<bucketSize:
      bucketDifference += abs(differenceBuffer[x0 * bucketSize + i])
    if bucketDifference / bucketSize.float > 0.05:
      currentDifference += 1.0 / 128.0
    else:
      currentDifference += 0.0

  let nextDifference = lerp(difference, currentDifference, 0.05)

  let mx = x div 16
  let my = y div 16

  if difference > 0.09 and nextDifference <= 0.09:
    #playSound(SFX_DOOROPEN, 3)
    playSound(SFX_SOLVED, 2)
    if mget(mx+1,my) == 9:
      mset(mx+1,my,10)
      for i in 0..5:
        particles.add(Particle(kind: dustParticle, pos: vec2f(((mx + 1) * 16 + 8).float,(my * 16).float + rnd(16.0)), vel: rndVec(0.5), ttl: 1.5, maxttl: 1.5, above: true))
    if mget(mx-1,my) == 9:
      mset(mx-1,my,10)
      for i in 0..5:
        particles.add(Particle(kind: dustParticle, pos: vec2f(((mx - 1) * 16 + 8).float,(my * 16).float + rnd(16.0)), vel: rndVec(0.5), ttl: 1.5, maxttl: 1.5, above: true))

    if mget(mx,my-1) == 9:
      mset(mx,my-1,10)
      for i in 0..5:
        particles.add(Particle(kind: dustParticle, pos: vec2f((mx * 16 + 8).float,((my - 1) * 16).float + rnd(16.0)), vel: rndVec(0.5), ttl: 1.5, maxttl: 1.5, above: true))

    if mget(mx,my+1) == 9:
      mset(mx,my+1,10)
      for i in 0..5:
        particles.add(Particle(kind: dustParticle, pos: vec2f((mx * 16 + 8).float,((my + 1) * 16).float + rnd(16.0)), vel: rndVec(0.5), ttl: 1.5, maxttl: 1.5, above: true))

  elif difference <= 0.10 and nextDifference > 0.10:
    #playSound(SFX_DOOROPEN, 3)
    playSound(SFX_UNSOLVED, 2)
    if mget(mx+1,my) == 10:
      mset(mx+1,my,9)
    if mget(mx-1,my) == 10:
      mset(mx-1,my,9)
    if mget(mx,my-1) == 10:
      mset(mx,my-1,9)
    if mget(mx,my+1) == 10:
      mset(mx,my+1,9)

  difference = nextDifference

  procCall update(Box(self), dt)


proc newPlayer(x,y: int): Player =
  result = new(Player)
  result.name = "player"
  result.x = x
  result.y = y
  result.xv = 0.0
  result.yv = 0.0
  result.remx = 0.0
  result.remy = 0.0
  result.hitbox.x = 5
  result.hitbox.y = 4
  result.hitbox.w = 6
  result.hitbox.h = 12
  result.jump = false
  result.wasOnGround = false
  result.wasOnWall = false
  result.dir = 1
  result.socket = newSocket(result, x + 8, y + 8)

proc newOscBox(x,y: int, freq: float32, shape: OscShape, phaseMod: bool = false): OscBox =
  result = new(OscBox)
  result.name = "osc:" & $shape
  result.x = x
  result.y = y
  result.hitbox.x = 0
  result.hitbox.y = 0
  result.hitbox.w = 16
  result.hitbox.h = 16
  result.pulseWidth = PI
  result.freq = freq
  result.shape = shape
  result.hasPhaseMod = phaseMod
  result.phaseMod = 0.0

  if phaseMod:
    result.inputSockets = @[newSocket(result, x, y + 8)]
  else:
    result.inputSockets = @[]
  result.outputSockets = @[newSocket(result, x + 16, y + 8)]

proc newTargetBox(x,y: int): TargetBox =
  result = new(TargetBox)
  result.name = "target"
  result.x = x
  result.y = y
  result.hitbox.x = 0
  result.hitbox.y = 0
  result.hitbox.w = 16
  result.hitbox.h = 16
  result.targetInputs = @[]
  if not isSolid(mget(x div 16 - 1, y div 16)):
    result.inputSockets = @[newSocket(result, x, y + 8)]
  if not isSolid(mget(x div 16, y div 16 - 1)):
    result.inputSockets = @[newSocket(result, x + 8, y)]
  if not isSolid(mget(x div 16 + 1, y div 16)):
    result.inputSockets = @[newSocket(result, x + 16, y + 8)]
  else:
    result.inputSockets = @[newSocket(result, x + 8, y + 16)]
  result.outputSockets = @[]

proc newSplitterBox(x,y: int): SplitterBox =
  result = new(SplitterBox)
  result.name = "splitter"
  result.x = x
  result.y = y
  result.hitbox.x = 0
  result.hitbox.y = 0
  result.hitbox.w = 16
  result.hitbox.h = 16

  result.inputSockets = @[newSocket(result, x, y + 8)]
  result.outputSockets = @[
    newSocket(result, x + 16, y + 5),
    newSocket(result, x + 16, y + 12)
  ]

proc newAlterBox(x,y: int, kind: AlterKind): AlterBox =
  result = new(AlterBox)
  result.name = "alter:" & $kind
  result.x = x
  result.y = y
  result.hitbox.x = 0
  result.hitbox.y = 0
  result.hitbox.w = 16
  result.hitbox.h = 16
  result.kind = kind

  if kind == akInvert or kind == akDiv2:
    result.inputSockets = @[newSocket(result, x, y + 8)]
  else:
    result.inputSockets = @[newSocket(result, x, y + 5), newSocket(result, x, y + 12)]
  result.outputSockets = @[newSocket(result, x + 16, y + 8)]

proc newFilterBox(x,y: int, kind: FilterKind): FilterBox =
  result = new(FilterBox)
  result.name = "fx:" & $kind
  result.x = x
  result.y = y
  result.hitbox.x = 0
  result.hitbox.y = 0
  result.hitbox.w = 16
  result.hitbox.h = 16
  result.cutoff = if kind == fkHP: 0.001 else: 0.05
  result.q = 0.1
  result.kind = kind

  result.inputSockets = @[newSocket(result, x, y + 8)]
  result.outputSockets = @[newSocket(result, x + 16, y + 8)]

proc isSolid(t: uint8): bool =
  return case t
  of 1,4,5,11,12,13,14,15,16,17,18,19,20,21,22,23,27,9,255: true
  else: false

proc isPlatform(t: uint8): bool =
  return case t
  of 3: true
  else: false

proc isTouchingType(x,y,w,h: int, check: proc(t: uint8): bool): bool =
  if x < startX - 16 or x + w > startX + 16 * 16 or y < startY or y >= startY + 8 * 16:
    return check(255)
  for i in max((startX-1) div 16,(x div 16))..min(startX+16*16,(x+w-1) div 16):
    for j in max((startY-1) div 16,(y div 16))..min(startY+10*16,(y+h-1) div 16):
      let t = mget(i,j)
      if check(t):
        return true
  return false

proc isSolid(self: Object, ox,oy: int): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, isSolid)

proc isTouchingType(self: Player, ox,oy: int, check: proc(t: uint8): bool): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, check)

proc moveX(self: Player, amount: float, start: float) =
  var step = amount.int.sgn
  for i in start..<abs(amount.int):
    if noclip or not isSolid(step, 0):
      x += step
      wasOnWall = false
    else:
      # hit something
      xv = 0
      remx = 0
      wasOnWall = true
      break

proc moveY(self: Player, amount: float, start: float) =
  var step = amount.int.sgn
  for i in start..<abs(amount.int):
    if not isSolid(0, step) and not (not fallThrough and step > 0 and (y mod 16 == 0) and isTouchingType(x+hitbox.x, y+hitbox.y+hitbox.h+step, hitbox.w, 1, isPlatform)):
      y += step
      wasOnGround = false
    else:
      # hit something
      yv = 0
      remy = 0
      if wasOnGround == false:
        playSound(SFX_LAND, 0)
        for i in 0..5:
          particles.add(Particle(kind: dustParticle, pos: vec2f(x.float,y.float) + vec2f(8.0, 15.0), vel: rndVec(0.2) + vec2f(0.0, -0.1), ttl: 0.5, maxttl: 0.5, above: true))
      wasOnGround = true
      jump = false

      break

method update(self: Player, dt: float) =
  if btnp(pcY):
    monitor = not monitor
    if monitor:
      playSound(SFX_MONITORON, 3)
    else:
      playSound(SFX_MONITOROFF, 3)

  if btn(pcLeft):
    xv -= 0.5
    dir = 0
  if btn(pcRight):
    xv += 0.5
    dir = 1
  if btn(pcA) and btn(pcDown):
    fallThrough = true
  elif btnp(pcA) and player.wasOnGround and not jump:
    yv = -3.0
    jump = true
    playSound(SFX_JUMP, 0)
    for i in 0..5:
      particles.add(Particle(kind: dustParticle, pos: vec2f(x.float,y.float) + vec2f(8.0, 15.0), vel: rndVec(0.2) + vec2f(xv * 0.05, yv * 0.05), ttl: 1.5, maxttl: 1.5, above: true))
    wasOnGround = false

  if abs(xv) > 0.1 and frame mod 15 == 0:
    if wasOnGround:
      particles.add(Particle(kind: dustParticle, pos: vec2f(x.float,y.float) + vec2f(8.0, 14.0), vel: rndVec(0.5), ttl: 0.5, maxttl: 0.5, above: true))
    walkFrame += 1
    playSound(SFX_STEP, 0)
    if walkFrame > 1:
      walkFrame = 0

  if btnp(pcB):
    if self.socket.connectedTo == nil:
      # if holding nothing, attach to nearest box's socket
      if player.nearestBox != nil and player.nearestBoxDist < 20.0:
          let ob = player.nearestBox
          # if on right side, check for outputs
          if player.x + player.hitbox.x >= ob.x + ob.hitbox.w:
            if ob.outputSockets.len > 0:
              let s = if ob.outputSockets.len > 1 and btn(pcDown): ob.outputSockets[1] else: ob.outputSockets[0]
              if s.connectedTo != nil:
                let currentTarget = s.connectedTo
                disconnect(s)
                connect(self.socket, currentTarget)
                player.connectedToInput = true
                playSound(SFX_PLUGOUT, 1)
              else:
                connect(s, self.socket)
                player.connectedToInput = false
                playSound(SFX_PLUGOUT, 1)

          # if on left side, check for inputs
          elif player.x + player.hitbox.x + player.hitbox.w <= ob.x:
            if ob.inputSockets.len > 0:
              let s = if ob.inputSockets.len > 1 and btn(pcDown): ob.inputSockets[1] else: ob.inputSockets[0]
              if s.connectedTo == nil:
                # not already connected, connect s to player
                connect(player.socket, s)
                player.connectedToInput = true
                playSound(SFX_PLUGOUT, 1)
              else:
                # already connected to something, disconnect this end
                let currentSource = s.connectedTo
                disconnect(s)
                connect(currentSource, self.socket)
                player.connectedToInput = false
                playSound(SFX_PLUGOUT, 1)
    else:
      # if we're holding a cable, connect it to something, or drop it
      if player.nearestBox != nil and player.nearestBoxDist < 20.0:
        # connect it to a socket
        let ob = player.nearestBox
        if player.connectedToInput == false and player.x + player.hitbox.x + player.hitbox.w <= ob.x and ob.inputSockets.len > 0:
          var sourceSocket = self.socket.connectedTo
          let s = if ob.inputSockets.len > 1 and btn(pcDown): ob.inputSockets[1] else: ob.inputSockets[0]
          if s.connectedTo != nil:
            disconnect(s)
          disconnect(sourceSocket, self.socket)
          connect(sourceSocket, s)
          for i in 0..(rnd(5)+1):
            particles.add(Particle(kind: sparkParticle, pos: vec2f(s.x.float, s.y.float), vel: rndVec(0.5), ttl: 0.5, maxttl: 0.5, above: true))
          playSound(SFX_PLUGIN, 1)
        # if you're trying to connect an input to an output...
        if player.connectedToInput and player.x + player.hitbox.x >= ob.x + ob.hitbox.w and ob.outputSockets.len > 0:
          var targetSocket = self.socket.connectedTo
          let s = if ob.outputSockets.len > 1 and btn(pcDown): ob.outputSockets[1] else: ob.outputSockets[0]
          if s.connectedTo != nil:
            disconnect(s)
          disconnect(self.socket)
          connect(s, targetSocket)
          for i in 0..(rnd(5)+1):
            particles.add(Particle(kind: sparkParticle, pos: vec2f(s.x.float, s.y.float), vel: rndVec(0.5), ttl: 0.5, maxttl: 0.5, above: true))
          playSound(SFX_PLUGIN, 1)
      if self.socket.connectedTo != nil:
        disconnect(self.socket)

  # gravity
  if wasOnWall and yv > 0:
    yv += 0.10
  else:
    if btn(pcA) and jump and yv < -0.2:
      yv += 0.08
    else:
      yv += 0.20

  let maxfall = if noclip: 0.0 elif wasOnWall: 1.0 else: 3.0
  if yv > maxfall:
    yv = maxfall

  moveX(xv * (if noclip: 2.0 else: 1.0), 0.0)
  moveY(yv, 0.0)

  fallThrough = false

  xv *= 0.7

  if dir == 0:
    self.socket.x = self.x + 4
  else:
    self.socket.x = self.x + 13
  self.socket.y = self.y + 12

method draw(self: Player) =
  if jump:
    spr(40, x, y, 1, 1, dir == 0)
  elif btn(pcDown):
    spr(32, x, y, 1, 1, dir == 0)
  elif abs(xv) > 0.1:
    if walkFrame == 0:
      spr(48, x, y, 1, 1, dir == 0)
    else:
      spr(56, x, y, 1, 1, dir == 0)
  else:
    spr(24, x, y, 1, 1, dir == 0)

proc loadLevel(newlevelId: int) =
  debug "loadLevel", newlevelId
  levelId = newLevelId
  loadMap("map.json")

  if player != nil:
    disconnect(player.socket)

  pauseAudio(1)
  objects = @[]
  hiddenObjects = @[]
  cables = @[]

  startX = levelId * 15 * 16
  startY = 0

  setCamera(startX, startY)

  let startTX = startX div 16
  let startTY = startY div 16

  transitionIn = 0.0
  transitionOut = 0.0

  var targetCounter = 0

  for y in startTY..<startTY+9:
    for x in startTX..<startTX+15:
      let t = mget(x,y)
      case t:
      of 24:
        var ob = newPlayer(x * 16, y * 16)
        objects.add(ob)
        player = ob
        mset(x,y,0)
      of 31:
        var ob = newOscBox(x * 16, y * 16, 32.0, oscSine, levelId >= 6)
        mset(x,y,16)
        objects.add(ob)
      of 39:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscTriangle)
        objects.add(ob)
      of 47:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscSquare)
        objects.add(ob)
      of 55:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscSaw)
        objects.add(ob)
      of 63:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscPulse)
        objects.add(ob)

      of 30:
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSine, levelId >= 6)
        mset(x,y,16)
        objects.add(ob)
      of 38:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscTriangle)
        objects.add(ob)
      of 46:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSquare)
        objects.add(ob)
      of 54:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSaw)
        objects.add(ob)
      of 62:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscPulse)
        objects.add(ob)

      of 29:
        var ob = newOscBox(x * 16, y * 16, 128.0, oscSine, levelId >= 6)
        mset(x,y,16)
        objects.add(ob)
      of 37:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscTriangle)
        objects.add(ob)
      of 45:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscSquare)
        objects.add(ob)
      of 53:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscSaw)
        objects.add(ob)
      of 61:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscPulse)
        objects.add(ob)

      of 28:
        var ob = newOscBox(x * 16, y * 16, 256.0, oscSine, levelId >= 6)
        mset(x,y,16)
        objects.add(ob)
      of 36:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscTriangle)
        objects.add(ob)
      of 44:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscSquare)
        objects.add(ob)
      of 52:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscSaw)
        objects.add(ob)
      of 60:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscPulse)
        objects.add(ob)

      of 15:
        var ob = newSplitterBox(x * 16, y * 16)
        objects.add(ob)
      of 17:
        var ob = newAlterBox(x * 16, y * 16, akAdd)
        objects.add(ob)
      of 18:
        var ob = newAlterBox(x * 16, y * 16, akMul)
        objects.add(ob)
      of 19:
        var ob = newAlterBox(x * 16, y * 16, akInvert)
        objects.add(ob)
      of 20:
        var ob = newFilterBox(x * 16, y * 16, fkLP)
        objects.add(ob)
      of 21:
        var ob = newFilterBox(x * 16, y * 16, fkHP)
        objects.add(ob)
      of 22:
        var ob = newAlterBox(x * 16, y * 16, akDiv2)
        objects.add(ob)
      of 23:
        var ob = newTargetBox(x * 16, y * 16)
        objects.add(ob)
        ob.targetInputs.add(newSocket(ob,0,0))

        # create the hidden machines
        case newLevelId:
        of 0:
          var hosc = newOscBox(0,0, 32.0, oscSaw)
          connect(hosc.outputSockets[0], ob.targetInputs[0], false)
          hiddenObjects.add(hosc)
        of 1:
          var hosc1 = newOscBox(0,0, 64.0, oscSine)
          var hosc2 = newOscBox(0,0, 128.0, oscSquare)
          var hadd = newAlterBox(0,0, akAdd)
          connect(hosc1.outputSockets[0], hadd.inputSockets[0], false)
          connect(hosc2.outputSockets[0], hadd.inputSockets[1], false)
          connect(hadd.outputSockets[0], ob.targetInputs[0], false)
          hiddenObjects.add(hosc1)
          hiddenObjects.add(hosc2)
          hiddenObjects.add(hadd)
        of 2:
          var hosc1 = newOscBox(0,0, 32.0, oscSquare)
          var hosc2 = newOscBox(0,0, 64.0, oscSaw)
          var hmul = newAlterBox(0,0, akMul)
          var hinv = newAlterBox(0, 0, akInvert)
          connect(hosc1.outputSockets[0], hmul.inputSockets[0], false)
          connect(hosc2.outputSockets[0], hinv.inputSockets[0], false)
          connect(hinv.outputSockets[0], hmul.inputSockets[1], false)
          connect(hmul.outputSockets[0], ob.targetInputs[0], false)
          hiddenObjects.add(hosc1)
          hiddenObjects.add(hosc2)
          hiddenObjects.add(hinv)
          hiddenObjects.add(hmul)
        of 3:
          var hosc3 = newOscBox(0,0, 128.0, oscSine)
          var hosc2 = newOscBox(0,0, 64.0, oscSine)
          var hadd = newAlterBox(0,0, akAdd)
          connect(hosc3.outputSockets[0], hadd.inputSockets[0], false)
          connect(hosc2.outputSockets[0], hadd.inputSockets[1], false)
          connect(hadd.outputSockets[0], ob.targetInputs[0], false)
          hiddenObjects.add(hosc3)
          hiddenObjects.add(hosc2)
          hiddenObjects.add(hadd)
        of 4:
          case targetCounter:
          of 0:
            # tri1 + (pls3 / 2) inverted
            var hoscTri1 = newOscBox(0,0, 32.0, oscTriangle)
            var hoscPls3 = newOscBox(0,0, 128.0, oscPulse)
            var hdiv2 = newAlterBox(0,0, akDiv2)
            var hinv = newAlterBox(0,0, akInvert)
            var hadd = newAlterBox(0,0, akAdd)
            connect(hoscTri1.outputSockets[0], hadd.inputSockets[0], false)
            connect(hoscPls3.outputSockets[0], hdiv2.inputSockets[0], false)
            connect(hdiv2.outputSockets[0], hadd.inputSockets[1], false)
            connect(hadd.outputSockets[0], hinv.inputSockets[0], false)
            connect(hinv.outputSockets[0], ob.targetInputs[0], false)
            hiddenObjects.add(hoscTri1)
            hiddenObjects.add(hoscPls3)
            hiddenObjects.add(hdiv2)
            hiddenObjects.add(hadd)
            hiddenObjects.add(hinv)
          of 1:
            var hoscSin4 = newOscBox(0,0, 256.0, oscSine)
            var hoscSqr1 = newOscBox(0,0, 32.0, oscSquare)
            var hmul = newAlterBox(0,0, akMul)
            connect(hoscSin4.outputSockets[0], hmul.inputSockets[0], false)
            connect(hoscSqr1.outputSockets[0], hmul.inputSockets[1], false)
            connect(hmul.outputSockets[0], ob.targetInputs[0], false)
            hiddenObjects.add(hoscSin4)
            hiddenObjects.add(hoscSqr1)
            hiddenObjects.add(hmul)
          else:
            discard
        of 5:
          # sin challenge
          var hoscSin2 = newOscBox(0,0, 64.0, oscSine)
          var hoscSin3 = newOscBox(0,0, 128.0, oscSine)
          var hoscSin4 = newOscBox(0,0, 256.0, oscSine)

          var hadd = newAlterBox(0,0, akAdd)
          var hmul = newAlterBox(0,0, akMul)
          var hdiv = newAlterBox(0,0, akDiv2)
          connect(hoscSin2.outputSockets[0], hadd.inputSockets[0])
          connect(hoscSin3.outputSockets[0], hadd.inputSockets[1])
          connect(hoscSin4.outputSockets[0], hmul.inputSockets[0])
          connect(hadd.outputSockets[0], hmul.inputSockets[1])
          connect(hmul.outputSockets[0], hdiv.inputSockets[0])
          connect(hdiv.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSin2)
          hiddenObjects.add(hoscSin3)
          hiddenObjects.add(hoscSin4)
          hiddenObjects.add(hadd)
          hiddenObjects.add(hmul)
          hiddenObjects.add(hdiv)
        of 6:
          # introduce FM
          var hoscSin1 = newOscBox(0,0, 32.0, oscSine, true)
          var hoscSin1a = newOscBox(0,0, 32.0, oscSine, true)
          var hoscSin4 = newOscBox(0,0, 256.0, oscSine, true)
          connect(hoscSin4.outputSockets[0], hoscSin1.inputSockets[0])
          connect(hoscSin1.outputSockets[0], hoscSin1a.inputSockets[0])
          connect(hoscSin1a.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSin4)
          hiddenObjects.add(hoscSin1)
          hiddenObjects.add(hoscSin1a)
        of 7:
          # FM + Splitter
          var hoscSin1 = newOscBox(0,0, 32.0, oscSine, true)
          var hoscSin4 = newOscBox(0,0, 256.0, oscSine, true)
          var hadd = newAlterBox(0,0, akAdd)
          var hsplit = newSplitterBox(0,0)
          connect(hoscSin1.outputSockets[0], hsplit.inputSockets[0])
          connect(hsplit.outputSockets[0], hadd.inputSockets[0])
          connect(hsplit.outputSockets[1], hadd.inputSockets[1])
          connect(hadd.outputSockets[0], hoscSin4.inputSockets[0])
          connect(hoscSin4.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSin1)
          hiddenObjects.add(hoscSin4)
          hiddenObjects.add(hsplit)
          hiddenObjects.add(hadd)
        of 8:
          # FM + Splitter Challenge
          var hoscSin1a = newOscBox(0,0, 32.0, oscSine, true)
          var hoscSin1b = newOscBox(0,0, 32.0, oscSine, true)
          var hoscSin1c = newOscBox(0,0, 32.0, oscSine, true)
          var hmul = newAlterBox(0,0, akMul)
          var hsplit = newSplitterBox(0,0)
          var hdiv = newAlterBox(0,0, akDiv2)
          connect(hoscSin1a.outputSockets[0], hmul.inputSockets[0])
          connect(hoscSin1b.outputSockets[0], hmul.inputSockets[1])
          connect(hmul.outputSockets[0], hsplit.inputSockets[0])
          connect(hsplit.outputSockets[0], hdiv.inputSockets[0])
          connect(hsplit.outputSockets[1], hoscSin1a.inputSockets[0])
          connect(hdiv.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSin1a)
          hiddenObjects.add(hoscSin1b)
          hiddenObjects.add(hoscSin1c)
          hiddenObjects.add(hmul)
          hiddenObjects.add(hsplit)
          hiddenObjects.add(hdiv)
        of 9:
          # Introduce LP + HP
          var hoscSaw4 = newOscBox(0,0, 256.0, oscSaw, false)
          var hoscSqr2 = newOscBox(0,0, 64.0, oscSquare, false)
          var hlp = newFilterBox(0,0, fkLP)
          var hhp = newFilterBox(0,0, fkHP)
          var hmul = newAlterBox(0,0, akMul)
          connect(hoscSaw4.outputSockets[0], hhp.inputSockets[0])
          connect(hhp.outputSockets[0], hlp.inputSockets[0])
          connect(hlp.outputSockets[0], hmul.inputSockets[0])
          connect(hoscSqr2.outputSockets[0], hmul.inputSockets[1])
          connect(hmul.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSaw4)
          hiddenObjects.add(hlp)
          hiddenObjects.add(hmul)
          hiddenObjects.add(hoscSqr2)
          hiddenObjects.add(hhp)
        of 10:
          # another simpleish filter puzzle
          var hoscSaw2 = newOscBox(0,0, 64.0, oscSaw, false)
          var hoscSaw3 = newOscBox(0,0, 128.0, oscSaw, false)
          var hoscSaw4 = newOscBox(0,0, 256.0, oscSaw, false)
          var hlp1 = newFilterBox(0,0, fkLP)
          var hlp2 = newFilterBox(0,0, fkLP)
          var hlp3 = newFilterBox(0,0, fkLP)
          var hadd = newAlterBox(0,0, akAdd)
          var hmul = newAlterBox(0,0, akMul)
          var hdiv = newAlterBox(0,0, akDiv2)
          connect(hoscSaw2.outputSockets[0], hlp1.inputSockets[0])
          connect(hoscSaw3.outputSockets[0], hlp2.inputSockets[0])
          connect(hoscSaw4.outputSockets[0], hlp3.inputSockets[0])
          connect(hlp1.outputSockets[0], hmul.inputSockets[0])
          connect(hlp2.outputSockets[0], hmul.inputSockets[1])
          connect(hlp3.outputSockets[0], hdiv.inputSockets[0])
          connect(hdiv.outputSockets[0], hadd.inputSockets[0])
          connect(hmul.outputSockets[0], hadd.inputSockets[1])
          connect(hadd.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSaw2)
          hiddenObjects.add(hoscSaw3)
          hiddenObjects.add(hoscSaw4)
          hiddenObjects.add(hlp1)
          hiddenObjects.add(hlp2)
          hiddenObjects.add(hlp3)
          hiddenObjects.add(hadd)
          hiddenObjects.add(hmul)
          hiddenObjects.add(hdiv)
        of 11:
          # filter challenge puzzle
          case targetCounter:
          of 0:
            var hoscSin2 = newOscBox(0,0, 64.0, oscSine, true)
            var hoscSaw1 = newOscBox(0,0, 32.0, oscSaw, false)
            var hinv = newAlterBox(0,0, akInvert)
            var hlp = newFilterBox(0,0, fkLP)
            connect(hoscSaw1.outputSockets[0], hlp.inputSockets[0])
            connect(hlp.outputSockets[0], hoscSin2.inputSockets[0])
            connect(hoscSin2.outputSockets[0], hinv.inputSockets[0])
            connect(hinv.outputSockets[0], ob.targetInputs[0])
            hiddenObjects.add(hoscSin2)
            hiddenObjects.add(hoscSaw1)
            hiddenObjects.add(hinv)
            hiddenObjects.add(hlp)
          of 1:
            var hoscSaw4 = newOscBox(0,0, 256.0, oscSaw, false)
            var hoscSin3 = newOscBox(0,0, 128.0, oscSine, true)
            var hhp = newFilterBox(0,0, fkHP)
            connect(hoscSaw4.outputSockets[0], hoscSin3.inputSockets[0])
            connect(hoscSin3.outputSockets[0], hhp.inputSockets[0])
            connect(hhp.outputSockets[0], ob.targetInputs[0])
            hiddenObjects.add(hoscSin3)
            hiddenObjects.add(hoscSaw4)
            hiddenObjects.add(hhp)
          else:
            discard
        of 12:
          var hoscSqr4 = newOscBox(0,0, 256.0, oscSquare, false)
          var hoscSqr1 = newOscBox(0,0, 32.0, oscSquare, false)
          var hmul = newAlterBox(0,0, akMul)
          var hadd = newAlterBox(0,0, akAdd)
          var hinv = newAlterBox(0,0, akInvert)
          var hdiv2 = newAlterBox(0,0, akDiv2)
          var hsplit = newSplitterBox(0,0)
          var hlp = newFilterBox(0,0, fkLP)
          connect(hoscSqr4.outputSockets[0], hsplit.inputSockets[0])
          connect(hoscSqr1.outputSockets[0], hlp.inputSockets[0])
          connect(hlp.outputSockets[0], hmul.inputSockets[0])
          connect(hsplit.outputSockets[0], hmul.inputSockets[1])
          connect(hsplit.outputSockets[1], hinv.inputSockets[0])
          connect(hinv.outputSockets[0], hdiv2.inputSockets[0])
          connect(hdiv2.outputSockets[0], hadd.inputSockets[0])
          connect(hmul.outputSockets[0], hadd.inputSockets[1])
          connect(hadd.outputSockets[0], ob.targetInputs[0])
          hiddenObjects.add(hoscSqr4)
          hiddenObjects.add(hoscSqr1)
          hiddenObjects.add(hmul)
          hiddenObjects.add(hadd)
          hiddenObjects.add(hinv)
          hiddenObjects.add(hdiv2)
          hiddenObjects.add(hsplit)
          hiddenObjects.add(hlp)
        else:
          discard

        targetCounter += 1
      else:
        discard

  if newLevelId != 0:
    objects.add(player)

  pauseAudio(0)

proc loadSoundFileStreaming(filename: string): ptr TSNDFILE =
  var info: Tinfo
  var fp = sndfile.open(filename.cstring, READ, info.addr)
  if fp == nil:
    raise newException(IOError, "Error opening vorbis file: " & filename)
  return fp

proc loadSoundFile(index: int, filename: string) =
  var info: Tinfo
  var fp = sndfile.open(filename.cstring, READ, info.addr)
  if fp == nil:
    raise newException(IOError, "Error opening vorbis file: " & filename)
  var sfx: SfxData = new(SfxData)
  sfx.data = newSeq[float32](info.frames)

  let count = fp.read_float(addr(sfx.data[0]), info.frames)
  discard fp.close()
  sfxLibrary[index] = sfx

proc gameInit() =
  loadSpriteSheet("spritesheet.png", 16, 16)
  loadFont("font5x5.png", " !\"#$%&'()*+,-./0123456789:;<=>?@abcdefghijklmnopqrstuvwxyz[\\]^_`ABCDEFGHIJKLMNOPQRSTUVWXYZ{:}~\n")
  ambience = loadSoundFileStreaming("assets/music/ambience1.ogg")

  loadSoundFile(0, "assets/sfx/plugin.ogg")
  loadSoundFile(1, "assets/sfx/plugout.ogg")
  loadSoundFile(2, "assets/sfx/jump.ogg")
  loadSoundFile(3, "assets/sfx/land.ogg")
  loadSoundFile(4, "assets/sfx/solved.ogg")
  loadSoundFile(5, "assets/sfx/unsolved.ogg")
  loadSoundFile(6, "assets/sfx/dooropen.ogg")
  loadSoundFile(7, "assets/sfx/step.ogg")
  loadSoundFile(8, "assets/sfx/monitoron.ogg")
  loadSoundFile(9, "assets/sfx/monitoroff.ogg")

  timerem = 60 * 60 * 60

  particles = initPool[Particle](512)

  for p in particles.mitems:
    p.ttl = 0

  particles.keepIf(proc(a: Particle): bool =
    a.ttl > 0.0
  )

  loadLevel(0)

proc gameUpdate(dt: float) =

  if btnp(pcStart) or btnp(pcBack):
    showMenu = not showMenu
    playSound(SFX_MONITORON,0)
    return

  if showMenu:
    if btnp(pcUp):
      menuOption -= 1
      if menuOption < 0:
        menuOption = 0
      playSound(SFX_PLUGIN,0)
    if btnp(pcDown):
      menuOption += 1
      if menuOption > 4:
        menuOption = 4
      playSound(SFX_PLUGIN,0)

    case menuOption:
    of 0:
      if btnp(pcLeft):
        waveVolume -= 0.1
        if waveVolume < 0.0:
          waveVolume = 0.0
        playSound(SFX_PLUGOUT,0)
      if btnp(pcRight):
        waveVolume += 0.1
        if waveVolume > 1.0:
          waveVolume = 1.0
        playSound(SFX_PLUGOUT,0)
    of 1:
      if btnp(pcLeft):
        ambienceVolume -= 0.1
        if ambienceVolume < 0.0:
          ambienceVolume = 0.0
        playSound(SFX_PLUGOUT,0)
      if btnp(pcRight):
        ambienceVolume += 0.1
        if ambienceVolume > 1.0:
          ambienceVolume = 1.0
        playSound(SFX_PLUGOUT,0)
    of 2:
      if btnp(pcLeft):
        sfxVolume -= 0.1
        if sfxVolume < 0.0:
          sfxVolume = 0.0
        playSound(SFX_PLUGOUT,0)
      if btnp(pcRight):
        sfxVolume += 0.1
        if sfxVolume > 1.0:
          sfxVolume = 1.0
        playSound(SFX_PLUGOUT,0)
    of 3:
      if btnp(pcA):
        showMenu = false
        playSound(SFX_MONITOROFF,0)
    of 4:
      if btnp(pcA):
        shutdown()
    else:
      discard
    return

  if gameComplete:
    if gameoverTimeout > 0:
      gameoverTimeout -= dt
      if gameoverTimeout <= 0:
        if timerem > 0:
          playSound(SFX_SOLVED,3)
        else:
          playSound(SFX_UNSOLVED,3)

    else:
      if timerem <= 0 and btnp(pcA):
        timerem = 60 * 60 * 60
        gameComplete = false
        playSound(SFX_SOLVED,3)
    return

  for i in 0..<objects.len:
    objects[i].update(dt)

  for i in 0..<hiddenObjects.len:
    hiddenObjects[i].update(dt)

  for cable in cables:
    cable.update(dt)

  cables.keepIf() do(a: Cable) -> bool:
    return a.toRemove == false

  # for all states
  for p in particles.mitems:
    p.ttl -= dt
    p.pos += p.vel
    p.vel *= 0.98

  particles.keepIf(
    proc(a: Particle): bool =
      a.ttl > 0.0
  )

  if player.x + player.hitbox.x + player.hitbox.w >= (levelId + 1) * 15 * 16:
    if transitionOut < 1.0:
      transitionOut += 0.05
    else:
      loadLevel(levelId + 1)
      transitionOut = 0.0
    return

  if levelId == 12:
    if mget((player.x + 8) div 16, (player.y + 16) div 16) == 8:
      gameComplete = true
      playSound(SFX_DOOROPEN, 3)

  timerem -= 1
  if timerem < 0:
    gameComplete = true

proc drawParticles() =
  for p in particles.mitems:
    if p.ttl > 0.0:
      case p.kind:
      of dustParticle:
        if p.ttl > p.maxttl * 0.5:
          spr(57, p.pos.x.int - 8, p.pos.y.int - 8, 1, 1, p.vel.x > 0, p.vel.y > 0)
        if p.ttl > p.maxttl * 0.25:
          spr(58, p.pos.x.int - 8, p.pos.y.int - 8, 1, 1, p.vel.x > 0, p.vel.y > 0)
        else:
          spr(59, p.pos.x.int - 8, p.pos.y.int - 8, 1, 1, p.vel.x > 0, p.vel.y > 0)
      of sparkParticle:
        if p.ttl > p.maxttl * 0.5:
          spr(50, p.pos.x.int - 8, p.pos.y.int - 8, 1, 1, p.vel.x > 0, p.vel.y > 0)
        else:
          spr(51, p.pos.x.int - 8, p.pos.y.int - 8, 1, 1, p.vel.x > 0, p.vel.y > 0)

proc gameDraw() =
  frame += 1
  cls()
  setColor(3)

  clip() # this shouldn't be necessary

  setCamera(startX, startY)

  mapDraw(startX div 16,startY div 16 ,15,9,startX,startY)

  for obj in objects:
    obj.draw()

  # draw connection cables
  for cable in cables:
    cable.draw()

  drawParticles()

  player.draw()


  var nearestBoxDist: float = Inf
  player.nearestBox = nil

  for obj in objects:
    if obj of Box:
      let box = Box(obj)
      if box.distanceFromPlayer < nearestBoxDist:
        nearestBoxDist = box.distanceFromPlayer
        player.nearestBox = box
        player.nearestBoxDist = nearestBoxDist

  # highlight the socket on nearest box
  if frame mod 10 < 5 and player.nearestBox != nil and nearestBoxDist < 20.0:
    setColor(15)
    if player.x + player.hitbox.x + player.hitbox.w <= player.nearestBox.x:
      if btn(pcDown) and player.nearestBox.inputSockets.len > 1:
        let socket = player.nearestBox.inputSockets[1]
        rectCorners(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)
      elif player.nearestBox.inputSockets.len > 0:
        let socket = player.nearestBox.inputSockets[0]
        rectCorners(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)
    elif player.socket.connectedTo == nil and player.x + player.hitbox.x >= player.nearestBox.x + player.nearestBox.hitbox.w:
      if btn(pcDown) and player.nearestBox.outputSockets.len > 1:
        let socket = player.nearestBox.outputSockets[1]
        rectCorners(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)
      elif player.nearestBox.outputSockets.len > 0:
        let socket = player.nearestBox.outputSockets[0]
        rectCorners(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)

  if monitor:
    var showTargetOsc = false
    if player.nearestBox of TargetBox:
      showTargetOsc = true
      let x = clamp(player.x - 32, startX + 4, startX + screenWidth - 64)
      let y = clamp(player.y - 32 - 8, startY + 4, startY + screenHeight - 32)
      let w = 64
      let h = 32
      player.nearestBox.drawOsc(x,y,w,h)
      setColor(14)
      rect(x-1,y-1,x-1+w+1,y-1+h+1)

    if player.socket.connectedTo != nil and not showTargetOsc:
      let box = Box(player.socket.connectedTo.obj)
      let x = clamp(player.x - 32, startX + 4, startX + screenWidth - 64)
      let y = clamp(player.y - 32 - 8, startY + 4, startY + screenHeight - 32)
      let w = 64
      let h = 32
      box.drawOsc(x,y,w,h)
      setColor(14)
      rect(x-1,y-1,x-1+w+1,y-1+h+1)
    if player.socket.connectedTo == nil and not showTargetOsc and player.nearestBox != nil and nearestBoxDist < 20.0:
      let x = clamp(player.x - 32, startX + 4, startX + screenWidth - 64)
      let y = clamp(player.y - 32 - 8, startY + 4, startY + screenHeight - 32)
      let w = 64
      let h = 32
      player.nearestBox.drawOsc(x,y,w,h)
      setColor(14)
      rect(x-1,y-1,x-1+w+1,y-1+h+1)

  setCamera()

  setColor(0)
  rectfill(screenWidth - 6 * 5 - 2, 1, screenWidth-2, 9)
  setColor(14)
  rect(screenWidth - 6 * 5 - 2, 1, screenWidth-2, 9)
  let minutes = timerem div 60 div 60
  let seconds = timerem div 60 mod 60
  print(align($minutes,2,'0') & ":" & align($seconds,2,'0'), screenWidth - 6 * 5, 3)

  setColor(15)
  if levelId == 0:
    print("JUMP [Z]  CONNECT [X]  SCOPE [C]", 4, screenHeight - 8)
  elif levelId == 1:
    print("[DOWN + X] CONNECT TO LOWER SOCKET", 4, screenHeight - 8)
  elif levelId == 2:
    print("USE SCOPE [C] TO COMPARE WAVES", 4, screenHeight - 8)
  elif levelId == 3:
    print("EXPERIEMENT WITH DIFFERENT COMPONENTS", 4, screenHeight - 8)
  elif levelId == 4:
    print("SCOPE [C] SHOWS BOTH INPUT AND OUTPUT", 4, screenHeight - 8)
  elif levelId == 6:
    print("CONNECT OSC->OSC TO MODULATE PHASE", 4, screenHeight - 8)
  elif levelId == 7:
    print("A SPLITTER CAN DUPLICATE A WAVE", 4, screenHeight - 8)
  elif levelId == 9:
    print("FILTER LOW AND HIGH FREQUENCIES", 4, screenHeight - 8)

  setColor(0)

  block:
    let edge = (transitionIn * screenWidth.float).int
    rectfill(edge, 0, screenWidth + 1, screenHeight)
    if transitionIn < 1.0:
      transitionIn += 0.02

  if transitionOut > 0.0:
    rectfill(0, 0, transitionOut * (screenWidth + 1).float, screenHeight)

  if gameComplete:
    setColor(0)
    rectfill(0, 0, screenWidth, screenHeight)

    if timerem > 0:
      if gameoverTimeout <= 0.0:
        setColor(15)
        printShadowC("THE REACTOR HAS BEEN REACTIVATED", screenWidth div 2, screenHeight div 2)
    else:
      if gameoverTimeout <= 0.0:
        setColor(15)
        printShadowC("ALL POWER HAS BEEN LOST FOREVER", screenWidth div 2, screenHeight div 2)
        printShadowC("KEEP PLAYING ANYWAY?", screenWidth div 2, screenHeight div 2 + 30)

  if showMenu:
    setColor(if menuOption == 0: 15 else: 11)
    printShadowC("WAVEFORM VOLUME: " & $((waveVolume * 100.0).int), screenWidth div 2, 30)
    setColor(if menuOption == 1: 15 else: 11)
    printShadowC("AMBIENCE VOLUME: " & $((ambienceVolume * 100.0).int), screenWidth div 2, 40)
    setColor(if menuOption == 2: 15 else: 11)
    printShadowC("SFX VOLUME: " & $((sfxVolume * 100.0).int), screenWidth div 2, 50)
    setColor(if menuOption == 3: 15 else: 11)
    printShadowC("CONTINUE", screenWidth div 2, 60)
    setColor(if menuOption == 4: 15 else: 11)
    printShadowC("QUIT GAME", screenWidth div 2, 80)

proc audioCallback(samples: pointer, nSamples: int) =
  # add in ambience first
  if not gameComplete:
    let read = ambience.read_float(cast[ptr cfloat](samples), nSamples.TCOUNT)
    if read < nSamples:
      discard ambience.seek(0, SEEK_SET)
  let samples = cast[ptr array[int32.high,float32]](samples)

  # mix in some sfx

  var lastSample: float32
  for i in 0..<nSamples:
    samples[i] *= ambienceVolume
    if i mod 2 == 0:
      lastSample = 0.0

      for j in 0..<sfxChannels.len:
        if sfxChannels[j].sfx != nil:
          lastSample += sfxChannels[j].sfx.data[sfxChannels[j].pos] * sfxVolume
          sfxChannels[j].pos += 1
          if sfxChannels[j].pos == sfxChannels[j].sfx.data.len:
            sfxChannels[j].sfx = nil

      for j in 0..<objects.len:
        let obj = objects[j]
        if obj of Box:
          let box = Box(obj)
          box.process()
          if box == player.nearestBox and player.nearestBoxDist < 20.0 and box of TargetBox:
            lastSample += TargetBox(box).targetValue * 0.125 * (16.0 / box.distanceFromPlayer)
          elif box.outputSockets.len > 0 and ((player.socket.connectedTo != nil and player.socket.connectedTo == box.outputSockets[0]) or (player.nearestBox == box and player.nearestBoxDist < 20.0)):
            lastSample += box.value * 0.125 * waveVolume * (16.0 / max(box.distanceFromPlayer, 1.0))

      for j in 0..<hiddenObjects.len:
        let obj = hiddenObjects[j]
        if obj of Box:
          Box(obj).process()

      samples[i] += lastSample
    else:
      samples[i] += lastSample

nico.init("impbox", "minisyn")
nico.loadPaletteFromGPL("phase.gpl")
nico.createWindow("minisyn", 240, 144, 5)
nico.setFullSpeedGif(false)
nico.setRecordSeconds(20)

nico.setAudioCallback(audioCallback)

nico.run(gameInit, gameUpdate, gameDraw)
