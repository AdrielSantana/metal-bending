# Bend 2.0.5 on Apple M5 — six findings

*(Versão em português: [RELATORIO.md](RELATORIO.md))*

Notes from building three renderers in Bend over a couple of days: a Mandelbrot,
a voxel raycaster, and an interactive voxel world with break/place. Everything
here is reproducible from <https://github.com/AdrielSantana/metal-bending>.

Thanks for pointing me at `demos/app_slash_boss_3d/bend3d.bend` — reading it is
what produced findings 5 and 6.

**Method.** Bend 2.0.5, macOS 26.6.2, Apple M5 (10 CPU cores / 8 GPU cores).
AC power, Low Power Mode off, no thermal warning recorded. Every timing is
`IO.now()` around the computation *inside* the process, first run discarded as
warm-up, 5 runs, median reported with the min–max range. Earlier numbers I had
were taken on battery and were inflated up to 1.7x; those are not in here.

---

## 1. `f!(x)` and `f(x)` do not compute the same thing

The same 512² frame, checksummed as the sum of its pixel colours:

| binary | GPU | 10 cores | 1 thread |
|---|---|---|---|
| compiled with `total!(...)` | 4171263204 | 4171263204 | 4171263204 |
| compiled with `total(...)` | 4169746902 | 4169746902 | 4169746902 |

Each binary is deterministic across all three backends. They differ from *each
other*. So this is not GPU precision: the `!` binary gives the same answer on a
single CPU thread.

The delta, 1516302, decomposes exactly. As a colour it is `rgb(23, 35, 14)`,
and the grass colour in that scene is `rgb(117, 176, 73)`; 117·0.20 = 23.4,
176·0.20 = 35.2, 73·0.20 = 14.6. The shading factors in the code are 1.0 for a
top face, 0.68 for an x face and 0.48 for a z face — and 0.68 − 0.48 = 0.20.

So exactly **one pixel** picks the x face instead of the z face. That pixel's
ray hits a voxel edge where `tMaxX ≈ tMaxZ`, and the `<` tie-break falls the
other way.

The guide describes `!` only as *where* a call runs, so I did not expect it to
change a result.

**Repro:** `gfx/03_voxel.bend`, with and without the `!` in `view()`.
**Not reduced:** plain F32 arithmetic with and without `!` agrees, so it seems
tied to the comparison tie-break rather than to a single operation.

---

## 2. A read of a shared `Data` tree costs ~374 ns, which blocks voxel worlds

`Array` is a `Type`, so it has one owner and cannot be read by both sides of a
parallel call — unusable for a renderer where every pixel reads the world. So
the interactive demo stores the world as a `Data` quadtree over 32×32 columns,
each leaf a `U32` whose bit *y* means "block at height y", shared with `+`.
Editing rebuilds one five-node path; everything else stays shared. Breaking and
placing are verified bit-exact.

Cost, isolated by layer, at 512²:

| | ms/frame |
|---|---|
| zero tree reads (procedural column) | 17 (16–17) |
| **one** read per ray | 115 (111–116) |
| re-reading as the DDA crosses columns | ~5950 |

98 ms for 262144 reads is **374 ns per read** — five levels of pointer chasing
plus refcount traffic on a shared tree.

The consequence is that even one read per pixel costs 98 ms at 512², so the
demo runs at 128² (~360 ms/frame): it responds to the keyboard but is not
smooth. As far as I can tell this is the thing standing between Bend and a
chunked voxel world, and it is a runtime question rather than something I can
fix in the program.

**Repro:** `gfx/05_craft.bend`; the partition is three sed-level variants of
`refetch`.

---

## 3. Two O(n) functions in Base, and the O(1) forms are invisible to `grep`

- `U32.shln(a, n)` is **O(n)** — one recursive `U32.shl` per unit of `n`.
  Shifting by 20 is 20 calls.
- `U32.from_nat(n)` is **O(value)** — `U32.inc` recursively, n times.

The O(1) forms exist: `F32.to_u32`, `U32.to_f32`, `F32.sin`, `F32.cos`,
`F32.sqrt`, `F32.exp`, `F32.log`, `F32.atan`. But they are declared as **`law`**
(compiler primitives), not `def` — so

```
bend base | grep '^def F32'
```

does not list them, while `U32.from_nat` and `F32.to_nat` are right there as
`def`s with obvious names.

I hit this twice in one session. First I concluded Base had no trigonometry and
started writing a Taylor series by hand. Later I concluded there was no direct
F32↔U32 conversion and used the `Nat` round-trip, which is O(value), in an
inner loop.

**Honest caveat:** when I later swapped the round-trips for the primitives, it
measured **no speedup** (within noise, both programs). So this is a
discoverability complaint, not a performance one — the O(value) code may well
be optimised away. What it cost me was time and a wrong hypothesis, not
milliseconds.

This one seems worth flagging given your note that AIs write slow Bend: in this
case it was not an OpenGL mindset, it was that the fast path is invisible to
the obvious search and the slow path has the obvious name. A docs line, or
listing `law`-declared primitives in `bend base`, would have saved me both
mistakes.

---

## 4. `!` gives 5x on one workload and nothing on another; five explanations ruled out

Mandelbrot, 512² × 200 iterations, warm:

| | ms/frame |
|---|---|
| 1 thread | 213 (213–214) |
| 10 cores | 31 (30–33) |
| **GPU** | **6 (6–7)** |

Voxel raycaster, 512²: 10 cores 23 ms, GPU 24 ms. A tie, and slightly negative.

I tried to find the difference and failed. Tested and refuted:

| hypothesis | test | result |
|---|---|---|
| building the `Image` serialises | sum the colours instead of building the tree | 17 GPU / 17 CPU |
| ray divergence | drop the clip so every ray runs 96 identical steps | 48 GPU / 45 CPU |
| register pressure | Mandelbrot with 14 live F32 instead of 6 | 7 GPU / 33 CPU — keeps its 5x |
| `F32.sin`/`cos` in the loop | flat terrain, no trig at all | 8 GPU / 8 CPU |
| workload too small per dispatch | scale to 1024² and 2048² | 15/13 and 29/25 |

Trig turns out to cost half the frame (18 → 8 ms when removed) but costs the
same on both backends.

So: a reproducible case where `!` does not pay, with five causes eliminated. I
suspect you will see what I am missing immediately.

**Repro:** `gfx/04_voxel_fast.bend` for the raycaster; the ablations are small
variants of it.

---

## 5. Tile-granularity forking made no measurable difference in a raycaster

From `bend3d.bend`:

> `Cell.fork`: *"a fork per pixel drowns in scheduling, a fork per cell leaves
> lanes idle"*

My first version forked at all 9 quadtree levels — a fork per pixel, exactly
what that comment warns about. I rewrote it to fork down to 8×8 tiles and
resolve each tile's 64 pixels straight-line. Isolated ablation, same code,
only the fork depth changing:

| | GPU | CPU |
|---|---|---|
| fork per pixel (9 levels) | 25 (24–26) | 23 (23–26) |
| fork per tile 8×8 (6 levels) | 24 (23–24) | 24 (23–25) |

With those ranges this is not noise, it is zero.

I read this as workload-specific rather than as a correction. `bend3d` bins
triangles per tile, so a tile is a unit of *shared work* — its 256 pixels read
the same triangle list. In a raycaster every pixel is independent and there is
nothing to share, so scheduling never dominates. I kept the tile fork because
it is the library's idiom, not because it measured faster.

What actually made the raycaster 1.9x faster was clipping each ray against the
world's bounding box first — 45 → 24 ms — so a ray that looks at the sky walks
zero voxels instead of 96.

---

## 6. GPU warm-up makes single-shot timings misleading by ~8x

The same Mandelbrot computation:

- **6 ms** measured as the average of 10 runs inside one process
- **50 ms** measured once per process

Separately, process startup is ~30 ms for a CPU-only binary and **~150 ms with
`--gpu`** (Metal initialisation).

Both numbers are correct for their case — warm for a render loop, cold for a
one-shot job. But timing one run and calling it "per-frame cost" inflates the
result about 8x, and `time ./binary` on a `--gpu` build adds another 150 ms on
top. That is how I first concluded, wrongly, that the GPU lost to the CPU on
the Mandelbrot.

Might be worth a line in the guide next to the `--gpu` flag.

---

## Smaller notes

- **Metal has no FP64.** Confirmed on device by compiling MSL at runtime:
  `float`, `half` and `long` are accepted, `double` gives
  `error: 'double' is not supported in Metal`. So the veto is specific to
  64-bit *floating point*, not 64-bit width — a `U64` would be viable today.
  For deep fractal zoom the usual GPU workaround is double-float arithmetic
  (a double as a pair of floats), which fits in `F32`.
- **The window rasteriser is already a Metal kernel.** `effs/window_frame.c`
  walks the `Image` quadtree per pixel in MSL, so a window renders on the GPU
  even without `!`. That was a pleasant surprise and worth saying out loud in
  the guide.
- **`bend PROOF.bend` rejects what it should.** An open `?TODO` gives
  *"1 TODO found"*, and a false law gives *"expected 1n / observed 0n"*. The
  gate works.

---

## Where I was wrong along the way

Included because the mistakes are informative about the tooling:

- I published a 4% attribution for finding 5 before realising it was inside the
  noise of running on battery. It is zero.
- I removed the ray/box clip on a bad measurement — my "no clip" control kept a
  fuel value that is only sufficient *because* of the clip, so the control was
  silently truncating rays, which made it look fast. I then blamed the clip for
  the difference in the image. It was the control that was wrong.
- I compared two renders with an image differ and got "0 pixels differ". Both
  PNGs had the same MD5, which is also what you get from capturing the same
  window twice. I only trusted the comparison after validating the differ
  against a control that correctly reported 22.6%.

The general lesson, which cost me the most time: a control that runs faster is
usually doing less work because it is broken.
