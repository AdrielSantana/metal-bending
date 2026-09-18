import Base

# Mandelbrot on the GPU.
#
# An Image in Bend is a quadtree, so drawing one IS recursion -- and the
# four quadrants are independent, which is exactly what a parallel call
# wants. `scene!(..)` hands the whole recursion to Metal.

def rgb(r: U32, g: U32, b: U32) -> U32:
  (r * 65536 + g * 256 + b : U32)

# Escape-time iteration. Bend has no early return (mutual recursion is
# banned), so the loop always burns its full fuel and `Bool.pick` freezes
# z and the counter the moment the point escapes.
def mand(fuel: Nat, +cx: F32, +cy: F32, +zx: F32, +zy: F32, +i: U32) -> U32:
  match fuel:
    case 0n:
      i
    case 1n+f:
      +xx  = (zx * zx : F32)
      +yy  = (zy * zy : F32)
      +esc = (xx + yy > 4.0 : F32)
      nzx = Bool.pick(F32, esc, zx, (xx - yy + cx : F32))
      nzy = Bool.pick(F32, esc, zy, (2.0 * zx * zy + cy : F32))
      ni  = Bool.pick(U32, esc, i, (i + 1 : U32))
      mand(f, cx, cy, nzx, nzy, ni)

# inside the set -> black; outside -> a blue/violet ramp by escape speed
def shade(+i: U32) -> U32:
  Bool.pick(U32, (i > 49 : U32),
    0,
    rgb((i * 5 : U32), (i * 2 : U32), (60 + i * 3 : U32)))

# the quadtree: four independent quadrants, built in parallel
def scene(+k: Nat, +x: F32, +y: F32, s: F32) -> Image:
  match k:
    case 0n:
      Pix{shade(mand(50n, x, y, 0.0, 0.0, 0))}
    case 1n+j:
      +h = (s * 0.5 : F32)
      a b c d = scene(j, x, y, h) scene(j, (x + h : F32), y, h) scene(j, x, (y + h : F32), h) scene(j, (x + h : F32), (y + h : F32), h)
      Qua{a, b, c, d}

# depth 9 -> 512x512 pixels. `!` sends the whole recursion to the GPU.
def view() -> Image:
  scene!(9n, (0.0 - 2.2 : F32), (0.0 - 1.5 : F32), 3.0)

def tick(events: List<Event>, s: Unit) -> IO(Maybe<Unit>):
  match events:
    case Nil{}:
      IO.pure(Maybe<Unit>, Some{s})
    case Con{Close{}, rest}:
      IO.pure(Maybe<Unit>, None{})
    case Con{e, rest}:
      tick(rest, s)

def main() -> IO(Unit):
  App.run(~Unit, ~App{s => (s, view()), tick}, "Mandelbrot (Bend on Metal)", 512, 512, Unit{})
