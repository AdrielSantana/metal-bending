# Bend 2.0.6 on Apple M5 — six findings

*(Versão em português: [RELATORIO.md](RELATORIO.md))*

> **Correction, 18 Sep 2026.** Findings 2, 4 and 5 are rewritten and finding 1
> keeps its measurement but loses its explanation. The root cause was mine: I
> read `--gpu` as the switch that turns the device on, so most of my "GPU vs
> CPU" A/Bs had the GPU on both sides. With a correct baseline — removing the
> `!` — the missing variable is fork granularity, which is invisible on the CPU
> and worth up to 8x on the GPU. That is what finding 4 called an unexplained
> mystery, and it had also inflated finding 2 by up to 25x. Re-verified on
> 2.0.6, now with a checksum control proving each variant renders the same
> image. Findings 3 and 6 reproduced unchanged.

Notes from building three renderers in Bend over a couple of days: a Mandelbrot,
a voxel raycaster, and an interactive voxel world with break/place. Everything
here is reproducible from <https://github.com/AdrielSantana/metal-bending>.

Thanks for pointing me at `demos/app_slash_boss_3d/bend3d.bend` — reading it is
what produced findings 5 and 6.

**Method.** Bend 2.0.6, macOS 26.6.2, Apple M5 (10 CPU cores / 8 GPU cores).
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

Each binary is deterministic across all three columns. They differ from *each
other*.

I originally read that as proof this is not GPU precision, since the `!` binary
gives the same answer under `--threads 1`. That inference was wrong: a binary
containing `!` loads its `.gpu` Metal library and runs on the device whatever
the flags say (see Smaller notes), so all three columns of the first row are GPU
runs. An ordinary GPU/CPU numeric difference explains it. It is still worth
reporting, because the guide presents `!` as choosing *where* a call runs, not
*what* it returns.

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

## 2. A shared `Data` tree read is the dominant cost in a voxel world (REVISED)

`Array` is a `Type`, so it has one owner and cannot be read by both sides of a
parallel call — unusable for a renderer where every pixel reads the world. So
the interactive demo stores the world as a `Data` quadtree over 32×32 columns,
each leaf a `U32` whose bit *y* means "block at height y", shared with `+`.
Editing rebuilds one five-node path; everything else stays shared. Breaking and
placing are verified bit-exact.

Cost by layer at 512², all at the fork granularity from finding 4, 10 frames per
run, median of 3:

| what the DDA does on a column crossing | ms/frame |
|---|---|
| nothing — one read at ray start, then reuse | 19 (18–19) |
| recompute the column procedurally | 24 (22–34) |
| **read it from the shared tree** | **176 (176–179)** |
| read from the tree at *every* DDA step, not just crossings | 241 (226–253) |

Rows 2 and 3 are the isolation that matters: identical structure, identical
number of column lookups, only the mechanism differs. Going through the shared
tree costs **152 ms**, 7.3x the whole frame.

So the qualitative finding stands, and is cleaner than before: reads of a shared
`Data` tree dominate everything else in this program.

**What I withdraw from the earlier version of this finding.** I reported 374 ns
per read, a 5950 ms layer for re-reading, and the conclusion that this "blocks
voxel worlds" and left the demo at 128² and ~360 ms/frame, not smooth. All four
were measured at the starved fork granularity of finding 4:

- the 5950 ms layer is 241 ms, 25x lower;
- the 374 ns figure came from a 17 → 115 ms step for "one read per ray", and
  that layer now costs 19 ms in total, so I cannot reproduce the derivation and
  I am not replacing it with another per-read number — I never counted the
  actual column crossings per ray, so I could not have derived one honestly;
- Bendcraft at 128² runs at **28 ms/frame**, about 36 fps, not 360 ms. It is
  smooth.

Tree reads are still the thing to attack, but they do not stand between Bend and
a playable voxel world.

**Repro:** `gfx/05_craft.bend`; the layers are three one-line variants of
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

## 4. `!` pays on both workloads — the "tie" was fork granularity (CORRECTED)

**This replaces the finding 4 I sent earlier.** That version reported a mystery:
5x on a Mandelbrot, nothing on a raycaster, five explanations ruled out. The
mystery was my own measurement. All five ablations were run at the one fork
granularity that starves the GPU, and the answer was sitting in my own finding
5, which I had read as "no effect" because I only tested it where it has none.

Every row below is verified to render the same image: the harness sums all pixel
colours and the checksum is identical down each table. That check is what I was
missing before.

Raycaster, 512², `gfx/04`'s real quadtree-building path, 40 frames per run,
median of 5 runs:

| fork depth | leaf | with `!` | without `!`, 10 threads |
|---|---|---|---|
| 6 levels | 8×8 tile — *what I shipped* | 16 (16–20) | 21 (20–22) |
| 7 levels | 4×4 tile | **9 (9–12)** | — |
| 8 levels | 2×2 tile | 14 (11–15) | — |

Same sweep on a variant that sums colours instead of building the `Image`, so
both backends can be swept cheaply:

| fork depth | with `!` | without `!`, 10 threads |
|---|---|---|
| 6 levels (8×8) | 14 (14–15) | 19 (19) |
| 7 levels (4×4) | **6 (6–8)** | 19 (19–20) |
| 8 levels (2×2) | 8 (8) | 20 (19–20) |
| 9 levels (pixel) | 7 (7–8) | 21 (20–21) |

The CPU column is flat — granularity is irrelevant there, which is what my
finding 5 said. The `!` column moves 2.3x. So `!` is worth 21 → 9 ms on this
raycaster, and whether it reads as a win or a tie is decided entirely by how
deep the fork goes.

Bendcraft, 128², which reads a shared `World` tree per DDA step, 20 frames per
run, median of 3:

| fork depth | leaf | with `!` |
|---|---|---|
| 4 levels | 8×8 tile — *what I shipped* | 234 (232–236) |
| 5 levels | 4×4 tile | 87 (87) |
| 6 levels | 2×2 tile | **28 (28–34)** |

Without `!`, 10 threads: 178 (178). So the version I shipped was **slower on the
GPU than on the CPU**, and 8.4x slower than the same program forked two levels
deeper. That is the most useful number in this document.

The optimum is not universal — the raycaster wants 4×4 leaves, Bendcraft wants
2×2 — so it has to be swept per program.

**Where granularity is not enough.** `gfx/03`, the version without the ray/box
clip, already forks per pixel and still does not win: 48 (47–65) with `!` against
43 (42–46) on 10 threads without it. So the clip and the granularity are both
required — my earlier "drop the clip" ablation, which measured 48/45, was one of
the few that used a correct baseline, and it was telling me something real. The
claim here is only that granularity was the missing variable in `gfx/04` and
`gfx/05`, not that it explains every case.


The Mandelbrot table from the earlier report still stands: 214 (1 thread) / 31
(10 threads) / 7 with `!`. It was already forking to individual pixels, which is
why it showed its full speedup immediately and made the raycaster look broken by
comparison.

**Repro:** `gfx/04_voxel_fast.bend` and `gfx/05_craft.bend` now ship at their
measured optimum. Change the `fork!` depth and the leaf function together —
depth *k* with an *n*×*n* leaf must satisfy n·2^k = resolution — and check the
checksum does not move.

---

## 5. Fork granularity is free on the CPU and decisive on the GPU

From `bend3d.bend`:

> `Cell.fork`: *"a fork per pixel drowns in scheduling, a fork per cell leaves
> lanes idle"*

That comment is right and I misapplied it. I forked to 8×8 tiles because it is
the library's idiom, measured no difference, and concluded granularity did not
matter for a raycaster. What I had actually shown is that it does not matter *on
the CPU*, where the sweep is 19 / 19 / 20 / 21 ms and genuinely flat.

On the GPU the same sweep is 14 / 6 / 8 / 7 ms. So the finding is not
"granularity is irrelevant in a raycaster", it is "granularity is invisible on
the CPU and worth up to 8x on the GPU" — which is a much better thing to put in
front of someone arriving with an OpenGL mindset. The instinct to batch work per
tile is exactly wrong here, and a CPU run will not tell you.

My earlier table for this finding reported 24 vs 25 ms for tile vs per-pixel on
the GPU. I no longer trust it: it never verified that both variants rendered the
same pixels, and today's sweep, which does verify that by checksum, contradicts
it.

What helped independently, and still does: clipping each ray against the world's
bounding box first, 45 → 24 ms.

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

- **`--gpu` does not enable the GPU; it sizes its heap.** A binary containing
  `!` loads its `.gpu` Metal library and runs on the device with or without the
  flag — I verified this by hiding the `.gpu` file, which makes the binary
  recompile it in *both* cases. The guide reads
  `./file --gpu 4GB  # enables the GPU, with max 4GB memory`, and I took
  "enables" literally, so I spent a while treating no-flag runs as a CPU
  baseline. Any A/B built that way is GPU against GPU and will show a tie. The
  real CPU baseline is removing the `!`. Wording like "sets the GPU heap size"
  would have saved me most of a day.

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
- I benchmarked a "GPU vs CPU" A/B for a whole day where both sides ran on the
  GPU, because I read `--gpu` as the switch that turns the device on. Every tie
  in the first version of finding 4 came from that.
- I shipped two demos at a fork granularity that made the GPU slower than the
  CPU, then wrote a report calling that a mystery in the compiler. The variable
  I needed was one I had already measured and dismissed, in the very next
  finding.
- I wrote "it cost us 60x here" in a code comment about the O(value)
  conversions, published it, and only later measured that replacing them changes
  nothing.

The general lesson, which cost me the most time: a control that runs faster is
usually doing less work because it is broken. The second lesson, newer: make the
program print a checksum of what it rendered, and compare variants on it before
you compare them on time. Every wrong conclusion in the first version of this
document would have been caught by that one line.
