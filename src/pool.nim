import sequtils

type Pool*[T] = object
  items*: seq[T]

proc initPool*[T](size: int): Pool[T] =
  result.items = newSeq[T]()

proc add*[T](self: var Pool[T], item: T, force = false) =
  self.items.add(item)

proc keepIf*[T](self: var Pool[T], test: proc(a: T): bool) =
  self.items.keepIf(test)

iterator mitems*[T](self: var Pool[T]): var T {.inline.} =
  for i in mitems(self.items):
    yield i
