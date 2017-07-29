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

{.this:self.}

const BUFFERSIZE = 128

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

type Player = ref object of Object
  xv,yv: float
  dir: int
  remx,remy: float
  wasOnGround: bool
  wasOnWall: bool
  jump: bool
  fallThrough: bool
  socket: Socket
  nearestBox: Box
  nearestBoxDist: float

type OscShape = enum
  oscSine = "sin"
  oscPulse = "pulse"
  oscTriangle = "tri"
  oscSaw = "saw"
  oscNoise = "noise"

type OscBox = ref object of Box
  freq: float32
  phase: float32
  shape: OscShape
  pulseWidth: float32

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

type FilterBox = ref object of Box
  kind: FilterKind
  cutoff: float32
  q: float32
  drive: float32
  notch,lp,hp,band: float32
  limit: float32

## GLOBALS

var levelId: int
var startX,startY: int
var sampleRate: float32 = 44100.0
var invSampleRate: float32 = 1.0/sampleRate
var player: Player
var objects: seq[Object]
var hiddenObjects: seq[Object]
var cables: seq[Cable]
var timerem: int

var noise: array[4096, float32]
for i in 0..<noise.len:
  noise[i] = rnd(2.0) - 1.0

## PROCS

proc loadLevel(newlevelId: int)

proc newSocket(obj: Object, x,y: int): Socket =
  result = new(Socket)
  result.obj = obj
  result.x = x
  result.y = y

proc newCable(a: Socket, b: Socket): Cable =
  result = new(Cable)
  result.a = a
  result.b = b

proc connect(insock: Socket, outsock: Socket, cable = true) =
  debug("connect", insock.obj.name, outsock.obj.name)
  if insock.obj == outsock.obj:
    return
  insock.connectedTo = outsock
  outsock.connectedTo = insock
  if cable:
    cables.add(newCable(insock, outsock))

proc disconnect(outsock: Socket) =
  debug("disconnect", outsock.obj.name)
  if outsock.connectedTo != nil:
    let tmp = outsock.connectedTo
    outsock.connectedTo = nil
    disconnect(tmp)
  outsock.connectedTo = nil
  for cable in cables:
    if cable.a == outsock or cable.b == outsock:
      cable.toRemove = true

proc disconnect(insock: Socket, outsock: Socket) =
  debug("disconnect", insock.obj.name, outsock.obj.name)
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

  let Fs = sampleRate
  let freq = 2.0 * sin(PI * min(0.25, cutoff))
  let damp = min(2.0*(1.0 - pow(q, 0.25)), min(2.0, 2.0 / freq - freq * 0.5))

  notch = inA - damp * band
  lp = lp + freq * band
  hp = notch - lp
  band = freq * hp + band - drive * band * band * band

  case kind:
  of fkLP:
    value = 0.5 * lp
  of fkHP:
    value = 0.5 * hp

  value = saturate(value, limit)

  notch = value - damp * band
  lp = lp + freq * band
  hp = notch - lp
  band = freq * hp + band - drive * band * band * band

  value = saturate(value, limit)

  procCall process(Box(self))


method process(self: AlterBox) =
  var inA: float32 = 0.0
  var inB: float32 = 0.0

  if inputSockets[0].connectedTo != nil:
    inA = inputSockets[0].connectedTo.value
  if inputSockets.len > 1:
    if inputSockets[1].connectedTo != nil:
      inB = inputSockets[1].connectedTo.value

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
  case shape:
  of oscSine:
    value = sin(phase)
  of oscPulse:
    value = if phase < pulseWidth: -1.0 else: 1.0
  of oscTriangle:
    value = abs(phase / TAU * 2.0 - 1.0) * 2.0 - 1.0
  of oscSaw:
    value = (phase - PI) / PI
  of oscNoise:
    value = noise[((phase / TAU) * noise.len.float).int]

  phase += freq * invSampleRate * TAU
  phase = phase mod TAU

  procCall process(Box(self))

proc draw(self: Cable) =
  setColor(8)
  line(a.x, a.y, b.x, b.y)

method update(self: Object, dt: float) {.base.} =
  discard

method draw(self: Object) {.base.} =
  discard

method draw(self: Box) =
  for socket in outputSockets:
    setColor(13)
    circfill(socket.x, socket.y, 2)
    if socket.connectedTo == nil:
      setColor(0)
      circfill(socket.x, socket.y, 1)
  for socket in inputSockets:
    setColor(11)
    circfill(socket.x, socket.y, 2)
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
  setColor(6)
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
      pset(x + x0, y+h-1, 6)
    else:
      pset(x + x0, y+h-1, 8)

  if w > 64:
    printShadowR("SYNC: " & $(100 - (difference * 100).int) & "%", x + w, y + 2)

method draw(self: OscBox) =
  drawOsc(x+2,y+2,12,10)
  procCall draw(Box(self))

method draw(self: TargetBox) =
  drawOsc(x+2,y+2,12,10)
  procCall draw(Box(self))

method update(self: Box, dt: float) =
  let dx = self.x.float - player.x.float
  let dy = self.y.float - player.y.float
  distanceFromPlayer = sqrt(dx * dx + dy * dy)

method update(self: TargetBox, dt: float) =
  let bucketSize = differenceBuffer.len div 128

  var currentDifference = 0.0

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

  if difference > 0.05 and nextDifference <= 0.05:
    echo "opening door"
    debug mx,my
    debug mget(mx,my)
    if mget(mx+1,my) == 9:
      debug "adjacent door found"
      mset(mx+1,my,10)
    if mget(mx-1,my) == 9:
      debug "adjacent door found"
      mset(mx-1,my,10)
    if mget(mx,my-1) == 9:
      debug "adjacent door found"
      mset(mx,my-1,10)
    if mget(mx,my+1) == 9:
      debug "adjacent door found"
      mset(mx,my+1,10)
  elif difference <= 0.05 and nextDifference > 0.05:
    echo "closing door"
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

proc newOscBox(x,y: int, freq: float32, shape: OscShape): OscBox =
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
  result.inputSockets = @[newSocket(result, x, y + 8)]
  result.outputSockets = @[]

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
  result.cutoff = 0.5
  result.q = 0.5
  result.kind = kind
  result.limit = 0.95
  result.drive = 0.0

  result.inputSockets = @[newSocket(result, x, y + 8)]
  result.outputSockets = @[newSocket(result, x + 16, y + 8)]

proc isSolid(t: uint8): bool =
  return case t
  of 1,4,5,11,12,16,17,18,19,20,21,22,23,9,255: true
  else: false

proc isPlatform(t: uint8): bool =
  return case t
  of 3: true
  else: false

proc isTouchingType(x,y,w,h: int, check: proc(t: uint8): bool): bool =
  if x < startX or x + w > startX + 15 * 16 or y < startY or y >= startY + 8 * 16:
    return check(255)
  for i in max(startX div 16,(x div 16))..min(startX+15*16,(x+w-1) div 16):
    for j in max(startY div 16,(y div 16))..min(startY+9*16,(y+h-1) div 16):
      let t = mget(i,j)
      if check(t):
        return true
  return false

proc isSolid(self: Player, ox,oy: int): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, isSolid)

proc isTouchingType(self: Player, ox,oy: int, check: proc(t: uint8): bool): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, check)

proc moveX(self: Player, amount: float, start: float) =
  var step = amount.int.sgn
  for i in start..<abs(amount.int):
    if not isSolid(step, 0):
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
      wasOnGround = true
      jump = false
      break

method update(self: Player, dt: float) =
  if btn(pcLeft):
    xv -= 0.5
    dir = 0
  if btn(pcRight):
    xv += 0.5
    dir = 1
  if btn(pcA) and btn(pcDown):
    fallThrough = true
  elif btnp(pcA) and player.wasOnGround and not player.jump:
    yv -= 5.5
    jump = true
    wasOnGround = false

  if btnp(pcB):
    if self.socket.connectedTo == nil:
      # if holding nothing, attach to nearest box's output socket
      for obj in objects:
        if obj of Box:
          let ob = Box(obj)
          if ob.distanceFromPlayer < 20:
            if ob.outputSockets.len > 0:
              if ob.outputSockets[0].connectedTo != nil:
                disconnect(ob.outputSockets[0])
              connect(ob.outputSockets[0], self.socket)
              break
    else:
      # if we're holding a cable, connect it to something, or drop it
      var sourceSocket = self.socket.connectedTo
      for obj in objects:
        if obj of Box:
          let ob = Box(obj)
          if ob.distanceFromPlayer < 15:
              # connect it to a filter box
              if ob.inputSockets.len > 0:
                if ob.inputSockets.len > 1 and btn(pcDown):
                    if ob.inputSockets[1].connectedTo != nil:
                      disconnect(ob.inputSockets[1])
                    disconnect(sourceSocket, self.socket)
                    connect(sourceSocket, ob.inputSockets[1])
                else:
                  if ob.inputSockets[0].connectedTo != nil:
                    disconnect(ob.inputSockets[0])
                  disconnect(sourceSocket, self.socket)
                  connect(sourceSocket, ob.inputSockets[0])
              break
      if self.socket.connectedTo != nil:
        disconnect(self.socket)

  # gravity
  if wasOnWall and yv > 0:
    yv += 0.05
  else:
    yv += 0.35

  moveX(xv, 0.0)
  moveY(yv, 0.0)

  fallThrough = false

  xv *= 0.7
  #player.yv *= 1.0

  self.socket.x = self.x + 8
  self.socket.y = self.y + 8

method draw(self: Player) =
  spr(24, x, y, 1, 1, dir == 0)


proc loadLevel(newlevelId: int) =
  debug "loadLevel", newlevelId
  levelId = newLevelId
  loadMap("map.json")

  pauseAudio(1)
  objects = @[]
  hiddenObjects = @[]
  cables = @[]

  startX = levelId * 15 * 16
  startY = 0

  setCamera(startX, startY)

  let startTX = startX div 16
  let startTY = startY div 16

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
        var ob = newOscBox(x * 16, y * 16, 32.0, oscSine)
        mset(x,y,16)
        objects.add(ob)
      of 39:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscTriangle)
        objects.add(ob)
      of 47:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscPulse)
        objects.add(ob)
      of 55:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscSaw)
        objects.add(ob)
      of 63:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 32.0, oscNoise)
        objects.add(ob)

      of 30:
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSine)
        mset(x,y,16)
        objects.add(ob)
      of 38:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscTriangle)
        objects.add(ob)
      of 46:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscPulse)
        objects.add(ob)
      of 54:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSaw)
        objects.add(ob)
      of 62:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 64.0, oscNoise)
        objects.add(ob)

      of 29:
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSine)
        mset(x,y,16)
        objects.add(ob)
      of 37:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscTriangle)
        objects.add(ob)
      of 45:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscPulse)
        objects.add(ob)
      of 53:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscSaw)
        objects.add(ob)
      of 61:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 128.0, oscNoise)
        objects.add(ob)

      of 28:
        var ob = newOscBox(x * 16, y * 16, 64.0, oscSine)
        mset(x,y,16)
        objects.add(ob)
      of 36:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscTriangle)
        objects.add(ob)
      of 44:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscPulse)
        objects.add(ob)
      of 52:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscSaw)
        objects.add(ob)
      of 60:
        mset(x,y,16)
        var ob = newOscBox(x * 16, y * 16, 256.0, oscNoise)
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

        # create the hidden machines
        var hosc1 = newOscBox(0,0, 32.0, oscPulse)
        var hosc2 = newOscBox(0,0, 64.0, oscSaw)
        var hmul = newAlterBox(0,0, akMul)
        var hdiv2 = newAlterBox(0, 0, akDiv2)
        connect(hosc1.outputSockets[0], hmul.inputSockets[0], false)
        connect(hosc2.outputSockets[0], hdiv2.inputSockets[0], false)
        connect(hdiv2.outputSockets[0], hmul.inputSockets[1], false)
        ob.targetInputs.add(newSocket(ob,0,0))
        connect(hmul.outputSockets[0], ob.targetInputs[0], false)
        hiddenObjects.add(hosc1)
        hiddenObjects.add(hosc2)
        hiddenObjects.add(hdiv2)
        hiddenObjects.add(hmul)
        objects.add(ob)
      else:
        discard

  pauseAudio(0)

proc gameInit() =
  loadSpriteSheet("spritesheet.png", 16, 16)
  loadFont("font5x5.png", " !\"#$%&'()*+,-./0123456789:;<=>?@abcdefghijklmnopqrstuvwxyz[\\]^_`ABCDEFGHIJKLMNOPQRSTUVWXYZ{:}~\n")
  timerem = 60 * 60 * 60

  loadLevel(0)

proc gameUpdate(dt: float) =
  for i in 0..<objects.len:
    objects[i].update(dt)

  for i in 0..<hiddenObjects.len:
    hiddenObjects[i].update(dt)

  cables.keepIf() do(a: Cable) -> bool:
    return a.toRemove == false

  timerem -= 1

  if btnp(pcY) or player.x + player.hitbox.x + player.hitbox.w >= (levelId + 1) * 15 * 16 - 4:
    loadLevel(levelId + 1)
    return

  if player.x < levelId * 15 * 16 + 4:
    loadLevel(levelId - 1)
    return


proc gameDraw() =
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

  var showTargetOsc = false
  if player.nearestBox != nil and nearestBoxDist < 20.0:
    setColor(15)
    if player.socket.connectedTo != nil:
      if btn(pcDown) and player.nearestBox.inputSockets.len > 1:
        let socket = player.nearestBox.inputSockets[1]
        rect(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)
      elif player.nearestBox.inputSockets.len > 0:
        let socket = player.nearestBox.inputSockets[0]
        rect(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)
    else:
      for socket in player.nearestBox.outputSockets:
        rect(socket.x - 2, socket.y - 2, socket.x + 2, socket.y + 2)

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
    let x = clamp(player.x - 32, 4, screenWidth - 64)
    let y = clamp(player.y - 32 - 8, 4, screenHeight - 32)
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

proc audioCallback(samples: pointer, nSamples: int) =
  let samples = cast[ptr array[int32.high,float32]](samples)
  for i in 0..<nSamples:
    samples[i] = 0.0
    for j in 0..<objects.len:
      let obj = objects[j]
      if obj of Box:
        let box = Box(obj)
        box.process()
        if box == player.nearestBox and player.nearestBoxDist < 20.0 and box of TargetBox:
          samples[i] += TargetBox(box).targetValue * 0.25 * (16.0 / box.distanceFromPlayer)
        elif box.outputSockets.len > 0 and ((player.socket.connectedTo != nil and player.socket.connectedTo == box.outputSockets[0]) or (player.nearestBox == box and player.nearestBoxDist < 20.0)):
          samples[i] += box.value * 0.25 * (16.0 / box.distanceFromPlayer)

    for j in 0..<hiddenObjects.len:
      let obj = hiddenObjects[j]
      if obj of Box:
        Box(obj).process()

nico.init("impbox", "minisyn")
nico.loadPaletteFromGPL("phase.gpl")
nico.createWindow("minisyn", 240, 144, 5)
nico.setFullSpeedGif(false)
nico.setRecordSeconds(20)

nico.setAudioCallback(audioCallback)

nico.run(gameInit, gameUpdate, gameDraw)
