import Base

# Voxel raycaster, written the way Bend wants instead of the way OpenGL
# would. Three things learned from bend3d.bend (demos/app_slash_boss_3d):
#
#   1. "a fork per pixel drowns in scheduling, a fork per cell leaves lanes
#      idle" -- so fork down to 16x16 tiles and resolve the tile's 256
#      pixels straight-line, with no parallel call inside it.
#   2. "one bang, since a launch costs a fixed fee" -- a single `!` at the
#      top, not one per level.
#   3. A uniform 2x2 block collapses to ONE Pix, so flat regions cost
#      nothing downstream (bend3d's Blk.one).
#
# Plus one of our own: clip each ray against the world box first, so a ray
# that looks at the sky walks zero voxels instead of 110.
#
# Bend.pick evaluates both sides, so every real branch goes through a def
# that matches on a Bool parameter -- the same shape bend3d uses.

def rgb(r: U32, g: U32, b: U32) -> U32:
  (r * 65536 + g * 256 + b : U32)

# `F32.to_u32` / `U32.to_f32` are primitives (declared as `law`, not `def`).
# The `def` pair in Base -- U32.from_nat / F32.to_nat -- is O(value): it
# counts up one U32.inc at a time. Easy to miss -- though swapping these in
# measured NO speedup in this program, so the reason to prefer them is the
# complexity on paper, not a win I observed.
def floorf(+x: F32) -> F32:
  U32.to_f32(F32.to_u32(x))

def absf(+x: F32) -> F32:
  F32.max(x, (0.0 - x : F32))

def p2f(+p: U32) -> F32:
  (U32.to_f32(p) * 0.00390625 - 1.0 : F32)

# ---------- the world ----------

def lox() -> F32: 24.0
def hix() -> F32: 56.0
def loy() -> F32: 0.0
def hiy() -> F32: 17.0

def height(+vx: F32, +vz: F32) -> F32:
  floorf((8.0 + 3.0 * F32.sin((vx * 0.26 : F32)) + 2.5 * F32.cos((vz * 0.19 : F32)) : F32))

def solid(+vx: F32, +vy: F32, +vz: F32) -> Bool:
  +inx = (vx > 23.0 : F32) && (vx < 56.0 : F32)
  +inz = (vz > 23.0 : F32) && (vz < 56.0 : F32)
  +iny = (vy > (0.0 - 1.0) : F32)
  inx && inz && iny && (vy < height(vx, vz) : F32)

def voxel_color(+vy: F32, +vx: F32, +vz: F32) -> U32:
  +h = height(vx, vz)
  Bool.pick(U32, (vy > h - 2.0 : F32), rgb(117, 176, 73),
  Bool.pick(U32, (vy > h - 4.0 : F32), rgb(134, 96, 67), rgb(130, 130, 130)))

def scale(+c: U32, +k: F32) -> U32:
  F32.to_u32((U32.to_f32(c) * k : F32))

def dim(+c: U32, +k: F32) -> U32:
  +r = (c / 65536 : U32)
  +g = (c / 256 % 256 : U32)
  +b = (c % 256 : U32)
  rgb(scale(r, k), scale(g, k), scale(b, k))

def lit(+vy: F32, +vx: F32, +vz: F32, +axis: F32) -> U32:
  +k = Bool.pick(F32, (axis < 0.5 : F32), 0.68,
       Bool.pick(F32, (axis < 1.5 : F32), 1.0, 0.48))
  dim(voxel_color(vy, vx, vz), k)

# Quantised to 8-pixel bands so that a whole 8x8 tile of sky is ONE colour
# and collapses to a single Pix. bend3d calls this Sky.flat.
def sky_at(+yq: U32) -> U32:
  +g = (yq * 55 / 512 : U32)
  rgb((110 + g : U32), (150 + g : U32), 235)

def band(+y: U32) -> U32:
  (y / 8 * 8 : U32)

# ---------- DDA ----------

def dda(fuel: Nat,
        +vx: F32, +vy: F32, +vz: F32,
        +sx: F32, +sy: F32, +sz: F32,
        +mx: F32, +my: F32, +mz: F32,
        +ex: F32, +ey: F32, +ez: F32,
        +axis: F32, +col: U32) -> U32:
  match fuel:
    case 0n:
      col
    case 1n+f:
      +here = solid(vx, vy, vz) && (col < 1 : U32)
      ncol = Bool.pick(U32, here, lit(vy, vx, vz, axis), col)
      +ux = (mx < my : F32) && (mx < mz : F32)
      +uy = Bool.pick(Bool, ux, False{}, (my < mz : F32))
      nvx = Bool.pick(F32, ux, (vx + sx : F32), vx)
      nvy = Bool.pick(F32, uy, (vy + sy : F32), vy)
      nvz = Bool.pick(F32, ux, vz, Bool.pick(F32, uy, vz, (vz + sz : F32)))
      nmx = Bool.pick(F32, ux, (mx + ex : F32), mx)
      nmy = Bool.pick(F32, uy, (my + ey : F32), my)
      nmz = Bool.pick(F32, ux, mz, Bool.pick(F32, uy, mz, (mz + ez : F32)))
      naxis = Bool.pick(F32, ux, 0.0, Bool.pick(F32, uy, 1.0, 2.0))
      dda(f, nvx, nvy, nvz, sx, sy, sz, nmx, nmy, nmz, ex, ey, ez, naxis, ncol)

def run_dda(+ox: F32, +oy: F32, +oz: F32,
            +dx: F32, +dy: F32, +dz: F32, +v: U32) -> U32:
  +vx = floorf(ox)
  +vy = floorf(F32.max(oy, 0.0))
  +vz = floorf(oz)
  +px = (dx > 0.0 : F32)
  +py = (dy > 0.0 : F32)
  +pz = (dz > 0.0 : F32)
  +ax = F32.max(absf(dx), 0.00001)
  +ay = F32.max(absf(dy), 0.00001)
  +az = F32.max(absf(dz), 0.00001)
  +nx = Bool.pick(F32, px, (vx + 1.0 - ox : F32), (ox - vx : F32))
  +ny = Bool.pick(F32, py, (vy + 1.0 - oy : F32), (oy - vy : F32))
  +nz = Bool.pick(F32, pz, (vz + 1.0 - oz : F32), (oz - vz : F32))
  +c = dda(96n, vx, vy, vz,
           Bool.pick(F32, px, 1.0, (0.0 - 1.0 : F32)),
           Bool.pick(F32, py, 1.0, (0.0 - 1.0 : F32)),
           Bool.pick(F32, pz, 1.0, (0.0 - 1.0 : F32)),
           (nx / ax : F32), (ny / ay : F32), (nz / az : F32),
           (1.0 / ax : F32), (1.0 / ay : F32), (1.0 / az : F32),
           1.0, 0)
  Bool.pick(U32, (c < 1 : U32), sky_at(v), c)

# ---------- camera ----------

def cx() -> F32: 40.0
def cz() -> F32: 40.0
def cy() -> F32: 7.0
def eye_x(+a: F32) -> F32: (cx() + 30.0 * F32.cos(a) : F32)
def eye_y() -> F32: 23.0
def eye_z(+a: F32) -> F32: (cz() + 30.0 * F32.sin(a) : F32)

def norm3(+x: F32, +y: F32, +z: F32) -> F32:
  F32.sqrt((x * x + y * y + z * z : F32))

def flen(+a: F32) -> F32:
  norm3((cx() - eye_x(a) : F32), (cy() - eye_y() : F32), (cz() - eye_z(a) : F32))
def fwd_x(+a: F32) -> F32: ((cx() - eye_x(a)) / flen(a) : F32)
def fwd_y(+a: F32) -> F32: ((cy() - eye_y()) / flen(a) : F32)
def fwd_z(+a: F32) -> F32: ((cz() - eye_z(a)) / flen(a) : F32)
def rlen(+a: F32) -> F32: norm3(fwd_z(a), 0.0, (0.0 - fwd_x(a) : F32))
def rgt_x(+a: F32) -> F32: (fwd_z(a) / rlen(a) : F32)
def rgt_z(+a: F32) -> F32: ((0.0 - fwd_x(a)) / rlen(a) : F32)
def upv_x(+a: F32) -> F32: (0.0 - rgt_z(a) * fwd_y(a) : F32)
def upv_y(+a: F32) -> F32: (rgt_z(a) * fwd_x(a) - rgt_x(a) * fwd_z(a) : F32)
def upv_z(+a: F32) -> F32: (rgt_x(a) * fwd_y(a) : F32)

# ---------- one ray, clipped against the world box first ----------

# A real branch (Bool.pick would evaluate both sides): a ray that misses the
# world box never enters the DDA, and one that hits it starts at the box
# instead of at the camera.
def shoot(go: Bool, +ox: F32, +oy: F32, +oz: F32,
          +dx: F32, +dy: F32, +dz: F32, +v: U32) -> U32:
  match go:
    case False{}:
      sky_at(v)
    case True{}:
      run_dda(ox, oy, oz, dx, dy, dz, v)

def trace(+ox: F32, +oy: F32, +oz: F32,
          +dx: F32, +dy: F32, +dz: F32, +v: U32) -> U32:
  +rx = (1.0 / F32.max(absf(dx), 0.00001) * Bool.pick(F32, (dx > 0.0 : F32), 1.0, (0.0 - 1.0 : F32)) : F32)
  +ry = (1.0 / F32.max(absf(dy), 0.00001) * Bool.pick(F32, (dy > 0.0 : F32), 1.0, (0.0 - 1.0 : F32)) : F32)
  +rz = (1.0 / F32.max(absf(dz), 0.00001) * Bool.pick(F32, (dz > 0.0 : F32), 1.0, (0.0 - 1.0 : F32)) : F32)
  +xa = ((lox() - ox) * rx : F32)
  +xb = ((hix() - ox) * rx : F32)
  +ya = ((loy() - oy) * ry : F32)
  +yb = ((hiy() - oy) * ry : F32)
  +za = ((lox() - oz) * rz : F32)
  +zb = ((hix() - oz) * rz : F32)
  +tin  = F32.max(F32.max(F32.min(xa, xb), F32.min(ya, yb)), F32.max(F32.min(za, zb), 0.0))
  +tout = F32.min(F32.min(F32.max(xa, xb), F32.max(ya, yb)), F32.max(za, zb))
  +s = (tin + 0.002 : F32)
  shoot((tin < tout : F32), (ox + dx * s : F32), (oy + dy * s : F32), (oz + dz * s : F32), dx, dy, dz, v)

# Two optimisations were tried here and removed, both measured on device:
#
#   * a ray/world-box clip, to skip the DDA for sky rays
#   * a four-corner "is this tile all sky?" test, to emit one Pix per tile
#
# Neither made the frame faster (42 ms either way) and BOTH changed the
# image -- the tile test dropped 0.47% of the pixels, the box clip 6.2%.
# bend3d can cull per tile safely because its triangle binning knows
# exactly which tiles a shape touches. Four sample rays do not.
#
# What did matter was the fork granularity alone: 90 ms -> 41 ms.

def pixel(+pxi: U32, +pyi: U32, +a: F32) -> U32:
  +u = p2f(pxi)
  +v = p2f(pyi)
  +dx = (fwd_x(a) + 0.85 * u * rgt_x(a) + 0.85 * v * upv_x(a) : F32)
  +dy = (fwd_y(a) + 0.85 * v * upv_y(a) : F32)
  +dz = (fwd_z(a) + 0.85 * u * rgt_z(a) + 0.85 * v * upv_z(a) : F32)
  +n = norm3(dx, dy, dz)
  trace(eye_x(a), eye_y(), eye_z(a), (dx / n : F32), (dy / n : F32), (dz / n : F32), band(pyi))

# ---------- the tile: straight-line, no fork inside ----------

def one4(same: Bool, +k0: U32, +k1: U32, +k2: U32, +k3: U32) -> Image:
  match same:
    case True{}:
      Pix{k0}
    case False{}:
      Qua{Pix{k0}, Pix{k1}, Pix{k2}, Pix{k3}}

def t2(+x: U32, +y: U32, +a: F32) -> Image:
  +x1 = (x + 1 : U32)
  +y1 = (y + 1 : U32)
  +k0 = pixel(x, y, a)
  +k1 = pixel(x1, y, a)
  +k2 = pixel(x, y1, a)
  +k3 = pixel(x1, y1, a)
  one4(U32.is_eq(k0, k1) && U32.is_eq(k1, k2) && U32.is_eq(k2, k3), k0, k1, k2, k3)

def t4(+x: U32, +y: U32, +a: F32) -> Image:
  +x1 = (x + 2 : U32)
  +y1 = (y + 2 : U32)
  Qua{t2(x, y, a), t2(x1, y, a), t2(x, y1, a), t2(x1, y1, a)}

def t8_full(+x: U32, +y: U32, +a: F32) -> Image:
  +x1 = (x + 4 : U32)
  +y1 = (y + 4 : U32)
  Qua{t4(x, y, a), t4(x1, y, a), t4(x, y1, a), t4(x1, y1, a)}

def t8(+x: U32, +y: U32, +a: F32) -> Image:
  t8_full(x, y, a)

def t16(+x: U32, +y: U32, +a: F32) -> Image:
  +x1 = (x + 8 : U32)
  +y1 = (y + 8 : U32)
  Qua{t8(x, y, a), t8(x1, y, a), t8(x, y1, a), t8(x1, y1, a)}

# ---------- fork down to tiles, and only that far ----------

def fork(+k: Nat, +x: U32, +y: U32, +a: F32) -> Image:
  match k:
    case 0n:
      t8(x, y, a)
    case 1n+e:
      +h = U32.shln(8, e)
      +x1 = (x + h : U32)
      +y1 = (y + h : U32)
      p q r s = fork(e, x, y, a) fork(e, x1, y, a) fork(e, x, y1, a) fork(e, x1, y1, a)
      Qua{p, q, r, s}

def view(+a: F32) -> Image:
  fork!(6n, 0, 0, a)

def tick(events: List<Event>, a: F32) -> IO(Maybe<F32>):
  match events:
    case Nil{}:
      IO.pure(Maybe<F32>, Some{(a + 0.012 : F32)})
    case Con{Close{}, rest}:
      IO.pure(Maybe<F32>, None{})
    case Con{e, rest}:
      tick(rest, a)

def main() -> IO(Unit):
  App.run(~F32, ~App{+a => (a, view(a)), tick}, "Voxels fast (Bend on Metal)", 512, 512, 0.7)
