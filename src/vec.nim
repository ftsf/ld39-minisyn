import math

type
  Vec2[T] = tuple
    x,y: T
  Vec2f* = Vec2[float]
  Vec2i* = Vec2[int]

proc vec2f*(x,y: float): Vec2f =
  result.x = x
  result.y = y

proc vec2i*(x,y: int): Vec2i =
  result.x = x
  result.y = y

proc vec2i*(v: Vec2f): Vec2i =
  result.x = v.x.int
  result.y = v.y.int

proc vec2f*(v: Vec2i): Vec2f =
  result.x = v.x.float
  result.y = v.y.float

template x*[T](v: Vec2[T]): T =
  return v.x

template y*[T](v: Vec2[T]): T =
  return v.y

proc `x=`*[T](v: var Vec2[T], s: T) =
  v.x = s

proc `y=`*[T](v: var Vec2[T], s: T) =
  v.y = s

proc `+`*[T](a,b: Vec2[T]): Vec2[T] =
  result.x = a.x+b.x
  result.y = a.y+b.y

proc `+`*[T](a: Vec2[T], s: T): Vec2[T] =
  result.x = a.x+s
  result.y = a.y+s

proc `-`*[T](a,b: Vec2[T]): Vec2[T] =
  result.x = a.x-b.x
  result.y = a.y-b.y

proc `-`*[T](a: Vec2[T], s: T): Vec2[T] =
  result.x = a.x-s
  result.y = a.y-s

proc `-`*[T](a: Vec2[T]): Vec2[T] =
  result.x = -a.x
  result.y = -a.y

proc `*`*[T](a,b: Vec2[T]): Vec2[T] =
  result.x = a.x*b.x
  result.y = a.y*b.y

proc `*`*[T](a: Vec2[T], s: T): Vec2[T] =
  result.x = a.x*s
  result.y = a.y*s

proc `+=`*[T](a: var Vec2[T], b: Vec2[T]) =
  a.x+=b.x
  a.y+=b.y

proc `*=`*[T](a: var Vec2[T], s: T) =
  a.x*=s
  a.y*=s

proc `*`*[T](a: T, b: Vec2f): Vec2f =
  result.x = b.x * a
  result.y = b.y * a

proc length*[T](a: Vec2[T]): T =
  return sqrt(a.x*a.x + a.y*a.y)

proc lengthSqr*[T](a: Vec2[T]): T =
  return a.x*a.x + a.y*a.y

proc normalize*[T](a: Vec2[T]): Vec2[T] =
  let length = a.length()
  result.x = a.x / length
  result.y = a.y / length
