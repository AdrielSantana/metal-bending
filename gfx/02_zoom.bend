import Base

# Animated Mandelbrot zoom, re-rendered from scratch every frame.
#
# Note what Bend's restrictions do here. There is no early return, so the
# escape loop burns all 200 iterations on *every* pixel, even the ones that
# escape on step 2. On a CPU that is pure waste. On a GPU it is ideal: every
# lane runs the same number of steps, so there is no warp divergence at all.
# The language's constraint accidentally lands on the GPU-friendly shape.

def rgb(r: U32, g: U32, b: U32) -> U32:
  (r * 65536 + g * 256 + b : U32)

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

def shade(+i: U32) -> U32:
  Bool.pick(U32, (i > 199 : U32),
    0,
    rgb((30 + i * 4 % 226 : U32), (i * 7 % 256 : U32), (90 + i * 3 % 166 : U32)))

def scene(+k: Nat, +x: F32, +y: F32, s: F32) -> Image:
  match k:
    case 0n:
      Pix{shade(mand(200n, x, y, 0.0, 0.0, 0))}
    case 1n+j:
      +h = (s * 0.5 : F32)
      a b c d = scene(j, x, y, h) scene(j, (x + h : F32), y, h) scene(j, x, (y + h : F32), h) scene(j, (x + h : F32), (y + h : F32), h)
      Qua{a, b, c, d}

# zooming into the seahorse valley
def render(+s: F32) -> Image:
  +h = (s * 0.5 : F32)
  scene!(9n, (0.0 - 0.743643 - h : F32), (0.131825 - h : F32), s)

def tick(events: List<Event>, s: F32) -> IO(Maybe<F32>):
  match events:
    case Nil{}:
      IO.pure(Maybe<F32>, Some{(s * 0.97 : F32)})
    case Con{Close{}, rest}:
      IO.pure(Maybe<F32>, None{})
    case Con{e, rest}:
      tick(rest, s)

def main() -> IO(Unit):
  App.run(~F32, ~App{+s => (s, render(s)), tick}, "Mandelbrot zoom (Bend on Metal)", 512, 512, 3.0)
