# Out of Phase
# Puzzle platformer about sound and music, eaching synthesiser mechanics.


# Simple oscillators
# add and multiply waves
# doors/machines require an input waveform to match a certain pattern 

# CONTROLS
# Left Right
# A = Jump
# B = Connect / Disconnect

import nico

{.this:self.}

type Hitbox = tuple
  x,y,w,h: int

type Player = object
  x,y: int
  xv,yv: float
  dir: int
  remx,remy: float
  hitbox: Hitbox
  wasOnGround: bool
  wasOnWall: bool
  jump: bool
  fallThrough: bool

var player: Player

proc initPlayer(): Player =
  result.x = 16
  result.y = 16
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

proc isSolid(t: uint8): bool =
  return case t
  of 1,4,5,11,12,16,17: true
  else: false

proc isPlatform(t: uint8): bool =
  return case t
  of 3: true
  else: false

proc isTouchingType(x,y,w,h: int, check: proc(t: uint8): bool): bool =
  if x < 0 or x + w > screenWidth - 1 or y < 0 or y > screenHeight - 1:
    return check(255)
  for i in max(0,(x div 16))..min(15,(x+w-1) div 16):
    for j in max(0,(y div 16))..min(15,(y+h-1) div 16):
      let t = mget(i,j)
      if check(t):
        return true
  return false

proc isSolid(self: var Player, ox,oy: int): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, isSolid)

proc isTouchingType(self: var Player, ox,oy: int, check: proc(t: uint8): bool): bool =
  isTouchingType(x+hitbox.x+ox, y+hitbox.y+oy, hitbox.w, hitbox.h, check)

proc moveX(self: var Player, amount: float, start: float) =
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

proc moveY(self: var Player, amount: float, start: float) =
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

proc gameInit() =
  loadSpriteSheet("spritesheet.png", 16, 16)
  loadMap("map.json")
  player = initPlayer()

proc gameUpdate(dt: float) =
  if btn(pcLeft):
    player.xv -= 0.5
    player.dir = 0
  if btn(pcRight):
    player.xv += 0.5
    player.dir = 1
  if btnp(pcA) and btn(pcDown):
    player.fallThrough = true
  elif btnp(pcA) and player.wasOnGround and not player.jump:
    player.yv -= 5.5
    player.jump = true
    player.wasOnGround = false

  # gravity
  player.yv += 0.35

  player.moveX(player.xv, 0.0)
  player.moveY(player.yv, 0.0)

  player.fallThrough = false

  player.xv *= 0.7
  #player.yv *= 1.0

proc gameDraw() =
  cls()
  setColor(3)

  clip() # this shouldn't be necessary
  mapDraw(0,0,15,9,0,0)

  # draw player
  spr(24, player.x, player.y, 1, 1, player.dir == 0)

nico.init("impbox", "minisyn")
nico.loadPaletteFromGPL("phase.gpl")
nico.createWindow("minisyn", 240, 144, 5)
nico.setFullSpeedGif(false)
nico.setRecordSeconds(8)

nico.run(gameInit, gameUpdate, gameDraw)
