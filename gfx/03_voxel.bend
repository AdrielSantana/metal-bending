import Base

# A voxel raycaster with DDA traversal, rendered on the GPU.
#
# The world is a pure function of position -- no array, no chunk, no state.
# That is deliberate: `Array` in Bend is a `Type`, so it has exactly one
# owner and CANNOT be read by both sides of a parallel call. A procedural
# world sidesteps that entirely and stays perfectly parallel.
#
# The world sits in the positive octant because `F32.to_nat` (our floor)
# is undefined for negatives.

def rgb(r: U32, g: U32, b: U32) -> U32:
  (r * 65536 + g * 256 + b : U32)

def floorf(+x: F32) -> F32:
  F32.from_nat(F32.to_nat(x))

def absf(+x: F32) -> F32:
  F32.max(x, (0.0 - x : F32))

# ---------- the world ----------
# Takes voxel coordinates already, so there is no floor in the inner loop.

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
  U32.from_nat(F32.to_nat((F32.from_nat(U32.to_nat(c)) * k : F32)))

def dim(+c: U32, +k: F32) -> U32:
  +r = (c / 65536 : U32)
  +g = (c / 256 % 256 : U32)
  +b = (c % 256 : U32)
  rgb(scale(r, k), scale(g, k), scale(b, k))

# axis 0 = x face, 1 = y face (top), 2 = z face
def lit(+vy: F32, +vx: F32, +vz: F32, +axis: F32) -> U32:
  +k = Bool.pick(F32, (axis < 0.5 : F32), 0.68,
       Bool.pick(F32, (axis < 1.5 : F32), 1.0, 0.48))
  dim(voxel_color(vy, vx, vz), k)

# ---------- DDA ----------
#
# Amanatides & Woo: advance along whichever axis reaches its next voxel
# boundary first. That axis IS the face we enter through, so the normal
# comes out exact -- no guessing from fractional coordinates.
#
# Bend has no early return, so the walk always burns its full fuel and
# `col` (0 = nothing hit yet) freezes on the first solid voxel.

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
      # which boundary comes first?
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

# ---------- the camera ----------
# Top-level defs can be called freely (they are not affine), so the basis is
# recomputed per pixel instead of threaded through the quadtree.

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

# right = normalize(cross(fwd, up)), up = (0,1,0)  ->  (fz, 0, -fx)
def rlen(+a: F32) -> F32: norm3(fwd_z(a), 0.0, (0.0 - fwd_x(a) : F32))
def rgt_x(+a: F32) -> F32: (fwd_z(a) / rlen(a) : F32)
def rgt_z(+a: F32) -> F32: ((0.0 - fwd_x(a)) / rlen(a) : F32)

# up' = cross(right, fwd)
def upv_x(+a: F32) -> F32: (0.0 - rgt_z(a) * fwd_y(a) : F32)
def upv_y(+a: F32) -> F32: (rgt_z(a) * fwd_x(a) - rgt_x(a) * fwd_z(a) : F32)
def upv_z(+a: F32) -> F32: (rgt_x(a) * fwd_y(a) : F32)

def sky(+v: F32) -> U32:
  +g = U32.from_nat(F32.to_nat((F32.clamp((v * 0.5 + 0.5 : F32), 0.0, 1.0) * 55.0 : F32)))
  rgb((110 + g : U32), (150 + g : U32), 235)

# ---------- one ray ----------

def cast(+ox: F32, +oy: F32, +oz: F32,
         +dx: F32, +dy: F32, +dz: F32, +v: F32) -> U32:
  +vx = floorf(ox)
  +vy = floorf(oy)
  +vz = floorf(oz)
  +px = (dx > 0.0 : F32)
  +py = (dy > 0.0 : F32)
  +pz = (dz > 0.0 : F32)
  +ax = F32.max(absf(dx), 0.00001)
  +ay = F32.max(absf(dy), 0.00001)
  +az = F32.max(absf(dz), 0.00001)
  # distance to the first boundary on each axis
  +nx = Bool.pick(F32, px, (vx + 1.0 - ox : F32), (ox - vx : F32))
  +ny = Bool.pick(F32, py, (vy + 1.0 - oy : F32), (oy - vy : F32))
  +nz = Bool.pick(F32, pz, (vz + 1.0 - oz : F32), (oz - vz : F32))
  +c = dda(110n, vx, vy, vz,
           Bool.pick(F32, px, 1.0, (0.0 - 1.0 : F32)),
           Bool.pick(F32, py, 1.0, (0.0 - 1.0 : F32)),
           Bool.pick(F32, pz, 1.0, (0.0 - 1.0 : F32)),
           (nx / ax : F32), (ny / ay : F32), (nz / az : F32),
           (1.0 / ax : F32), (1.0 / ay : F32), (1.0 / az : F32),
           1.0, 0)
  Bool.pick(U32, (c < 1 : U32), sky(v), c)

def pixel(+u: F32, +v: F32, +a: F32) -> U32:
  +dx = (fwd_x(a) + 0.85 * u * rgt_x(a) + 0.85 * v * upv_x(a) : F32)
  +dy = (fwd_y(a) + 0.85 * v * upv_y(a) : F32)
  +dz = (fwd_z(a) + 0.85 * u * rgt_z(a) + 0.85 * v * upv_z(a) : F32)
  +n = norm3(dx, dy, dz)
  cast(eye_x(a), eye_y(), eye_z(a), (dx / n : F32), (dy / n : F32), (dz / n : F32), v)

# ---------- the quadtree ----------

def scene(+k: Nat, +u: F32, +v: F32, s: F32, +a: F32) -> Image:
  match k:
    case 0n:
      Pix{pixel(u, v, a)}
    case 1n+j:
      +h = (s * 0.5 : F32)
      p q r t = scene(j, u, v, h, a) scene(j, (u + h : F32), v, h, a) scene(j, u, (v + h : F32), h, a) scene(j, (u + h : F32), (v + h : F32), h, a)
      Qua{p, q, r, t}

def view(+a: F32) -> Image:
  scene!(9n, (0.0 - 1.0 : F32), (0.0 - 1.0 : F32), 2.0, a)

def tick(events: List<Event>, a: F32) -> IO(Maybe<F32>):
  match events:
    case Nil{}:
      IO.pure(Maybe<F32>, Some{(a + 0.012 : F32)})
    case Con{Close{}, rest}:
      IO.pure(Maybe<F32>, None{})
    case Con{e, rest}:
      tick(rest, a)

def main() -> IO(Unit):
  App.run(~F32, ~App{+a => (a, view(a)), tick}, "Voxels (Bend on Metal)", 512, 512, 0.7)
