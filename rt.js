// Bend's compiled form on WebGPU. Terms are u32 pairs (x = loc/value, y =
// tag<<24 | aux<<8); a task node is [args.., cont, (pend, idx)]; a dispatch
// runs one task per lane through the segment machine (switch on fid, an
// explicit per-lane stack); a fork pushes its four children onto the next
// queue, a finished task delivers into its parent's node and the last child
// queues the parent for the NEXT dispatch, so no lane ever reads what another
// wrote inside the same dispatch. G fork levels grow the frontier, one
// dispatch works each subtree sequentially (the runtime's `seq` path, with
// the K continuations on the stack), G join levels fold it back, one raster
// dispatch walks the quadtree into pixels.
const RUNTIME = `
const CAP: u32 = 262144u;
const WG: u32 = 64u;
const BUMP: u32 = 0u; const PBUMP: u32 = 1u; const ERR: u32 = 2u;
const CNT: u32 = 16u;
const ROOT: u32 = 20u;
const TAG_CTR: u32 = 2u; const TAG_TSK: u32 = 5u;
const CID_PIX: u32 = 15u; const CID_QUA: u32 = 16u;
const FID_SCENE: u32 = 7u; const FID_K26: u32 = 8u; const FID_K27: u32 = 9u; const FID_K28: u32 = 10u; const FID_K29: u32 = 11u; const FID_J26: u32 = 12u; const FID_EXIT: u32 = 51u; const FID_ENTER: u32 = 52u;
const HOLE = vec2<u32>(0xFFFFFFFFu, 0xFFFFFFFFu);

struct Params { mode: u32, qin: u32, qout: u32, qfree: u32, slab: u32, p0: u32, p1: u32, p2: u32 }
struct Frame { k: u32, w: u32, h: u32, lanes: u32, d: u32, p0: u32, p1: u32, p2: u32, v: array<vec4<u32>, 4> }

@group(0) @binding(0) var<storage, read_write> H: array<u32>;
@group(0) @binding(1) var<storage, read_write> stk: array<vec2<u32>>;
@group(0) @binding(2) var<storage, read_write> pend: array<atomic<u32>>;
@group(0) @binding(3) var<storage, read_write> ctl: array<atomic<u32>>;
@group(0) @binding(4) var<storage, read_write> Q: array<vec2<u32>>;
@group(0) @binding(5) var<uniform> P: Params;
@group(0) @binding(6) var<storage, read_write> pix: array<u32>;
@group(0) @binding(7) var<uniform> F: Frame;
@group(0) @binding(8) var<storage, read_write> args_out: array<atomic<u32>>;
@group(0) @binding(9) var<storage, read_write> args_free: array<atomic<u32>>;
@group(0) @binding(10) var<storage, read_write> a0: array<atomic<u32>>;
@group(0) @binding(11) var<storage, read_write> a1: array<atomic<u32>>;
@group(0) @binding(12) var<storage, read_write> a2: array<atomic<u32>>;
@group(0) @binding(13) var<storage, read> data: array<u32>;

var<private> gid: u32;
var<private> sp: i32;
var<private> atop: u32;
var<private> aend: u32;
var<private> r0: vec2<u32>; var<private> r1: vec2<u32>; var<private> r2: vec2<u32>; var<private> r3: vec2<u32>;
var<private> rn: u32;

fn mk(tag: u32, aux: u32, loc: u32) -> vec2<u32> { return vec2<u32>(loc, (tag << 24u) | (aux << 8u)); }
fn imm(v: u32) -> vec2<u32> { return vec2<u32>(v, 0u); }
fn ttag(t: vec2<u32>) -> u32 { return (t.y >> 24u) & 0x7Fu; }
fn taux(t: vec2<u32>) -> u32 { return (t.y >> 8u) & 0xFFFFu; }
fn ld(l: u32) -> vec2<u32> { return vec2<u32>(H[2u * l], H[2u * l + 1u]); }
fn st(l: u32, t: vec2<u32>) { H[2u * l] = t.x; H[2u * l + 1u] = t.y; }
fn fv(i: u32) -> f32 { return bitcast<f32>(F.v[i / 4u][i % 4u]); }
fn uv(i: u32) -> u32 { return F.v[i / 4u][i % 4u]; }
fn f(u: u32) -> f32 { return bitcast<f32>(u); }
fn b(x: f32) -> u32 { return bitcast<u32>(x); }
fn rgb(r: u32, g: u32, bb: u32) -> u32 { return r * 65536u + g * 256u + bb; }
fn arity(fd: u32) -> u32 { return 4u; }
fn stki(i: i32) -> u32 { return u32(sp + i) * F.lanes + gid; }
fn stk_ld(i: i32) -> vec2<u32> { return stk[stki(i)]; }
fn stk_st(i: i32, v: vec2<u32>) { stk[stki(i)] = v; }
fn alloc(n: u32) -> u32 { let l = atop; atop += n; if (atop > aend) { atomicStore(&ctl[ERR], 1u); } return l; }
fn push(q: u32, t: vec2<u32>) { let n = atomicAdd(&ctl[CNT + q], 1u); atomicMax(&args_out[0], (n + WG) / WG); Q[q * CAP + n] = t; }
fn task_node(fd: u32, cont: vec2<u32>, idx: u32, p: u32) -> u32 {
  let ar = arity(fd); let l = alloc(ar + 2u);
  st(l + ar, cont); st(l + ar + 1u, vec2<u32>(p, idx));
  return l;
}
fn deliver(cont: vec2<u32>, idx: u32, v: vec2<u32>) {
  if (all(cont == HOLE)) { atomicStore(&ctl[ROOT], v.x); atomicStore(&ctl[ROOT + 1u], v.y); atomicStore(&ctl[ROOT + 2u], 1u); return; }
  st(cont.x + idx, v);
  let tl = cont.x + arity(taux(cont));
  let p = H[2u * (tl + 1u)];
  if (atomicSub(&pend[p], 1u) == 1u) { push(P.qout, cont); }
}

//@PROGRAM

@compute @workgroup_size(1) fn reset() {
  for (var q = 0u; q < 3u; q++) { atomicStore(&ctl[CNT + q], 0u); }
  atomicStore(&a0[0], 1u); atomicStore(&a0[1], 1u); atomicStore(&a0[2], 1u);
  atomicStore(&a1[0], 0u); atomicStore(&a1[1], 1u); atomicStore(&a1[2], 1u);
  atomicStore(&a2[0], 0u); atomicStore(&a2[1], 1u); atomicStore(&a2[2], 1u);
  atomicStore(&ctl[PBUMP], 0u); atomicStore(&ctl[ERR], 0u); atomicStore(&ctl[ROOT + 2u], 0u);
  atop = 8u; aend = HEAP0;
  let ra = root_args();
  st(0u, imm(F.k)); st(1u, ra[0]); st(2u, ra[1]); st(3u, ra[2]); st(4u, HOLE); st(5u, vec2<u32>(0u, 0u));
  atomicStore(&ctl[BUMP], HEAP0);
  Q[0] = mk(TAG_TSK, FID_SCENE, 0u); atomicStore(&ctl[CNT], 1u);
}

@compute @workgroup_size(64) fn run(@builtin(global_invocation_id) g: vec3<u32>) {
  gid = g.x;
  if (gid == 0u) { atomicStore(&ctl[CNT + P.qfree], 0u); atomicStore(&args_free[0], 0u); }
  let n = atomicLoad(&ctl[CNT + P.qin]);
  if (gid >= n) { return; }
  var t = Q[P.qin * CAP + gid];
  atop = atomicAdd(&ctl[BUMP], P.slab); aend = atop + P.slab;
  sp = 0; let seq = P.mode != 0u;
  var fid = FID_ENTER;
  var guard = 0u;
  loop {
    guard += 1u; if (guard > 400000u) { atomicStore(&ctl[ERR], 2u); return; }
    switch fid {
      case FID_ENTER: {
        let fd = taux(t); let a = t.x; let war = arity(fd);
        stk_st(0, ld(a + war)); stk_st(1, imm(ld(a + war + 1u).y)); stk_st(2, imm(FID_EXIT)); sp += 3;
        r0 = ld(a); r1 = ld(a + 1u); r2 = ld(a + 2u); r3 = ld(a + 3u);
        fid = fd;
      }
      case FID_SCENE: {
        let k = r0.x; let x = r1; let y = r2; let s = r3;
        if (k == 0u) {
          r0 = leaf(x, y, s); rn = 1u; sp -= 1; fid = stk_ld(0).x;
        } else {
          let j = k - 1u; let s2 = kid_s(j, s);
          if (!seq) {
            let p = atomicAdd(&ctl[PBUMP], 1u); atomicStore(&pend[p], 4u);
            let t0 = task_node(FID_J26, stk_ld(-3), stk_ld(-2).x, p);
            let jt = mk(TAG_TSK, FID_J26, t0);
            for (var i = 0u; i < 4u; i++) {
              let c = task_node(FID_SCENE, jt, i, 0u);
              let xy = kid(i, j, x, y, s2);
              st(c, imm(j)); st(c + 1u, xy[0]); st(c + 2u, xy[1]); st(c + 3u, s2);
              st(t0 + i, HOLE);
              push(P.qout, mk(TAG_TSK, FID_SCENE, c));
            }
            return;
          }
          stk_st(0, imm(j)); stk_st(1, x); stk_st(2, y); stk_st(3, s2); stk_st(4, imm(FID_K26)); sp += 5;
          r0 = imm(j); r1 = x; r2 = y; r3 = s2;
        }
      }
      case FID_K26: { let j = stk_ld(-4); let x = stk_ld(-3); let y = stk_ld(-2); let h = stk_ld(-1);
        stk_st(0, r0); stk_st(1, imm(FID_K27)); sp += 2;
        let xy = kid(1u, j.x, x, y, h); r0 = j; r1 = xy[0]; r2 = xy[1]; r3 = h; fid = FID_SCENE; }
      case FID_K27: { let j = stk_ld(-5); let x = stk_ld(-4); let y = stk_ld(-3); let h = stk_ld(-2);
        stk_st(0, r0); stk_st(1, imm(FID_K28)); sp += 2;
        let xy = kid(2u, j.x, x, y, h); r0 = j; r1 = xy[0]; r2 = xy[1]; r3 = h; fid = FID_SCENE; }
      case FID_K28: { let j = stk_ld(-6); let x = stk_ld(-5); let y = stk_ld(-4); let h = stk_ld(-3);
        stk_st(0, r0); stk_st(1, imm(FID_K29)); sp += 2;
        let xy = kid(3u, j.x, x, y, h); r0 = j; r1 = xy[0]; r2 = xy[1]; r3 = h; fid = FID_SCENE; }
      case FID_K29: { sp -= 7; let d = r0; r0 = stk_ld(4); r1 = stk_ld(5); r2 = stk_ld(6); r3 = d; fid = FID_J26; }
      case FID_J26: { let nd = alloc(4u); st(nd, r0); st(nd + 1u, r1); st(nd + 2u, r2); st(nd + 3u, r3);
        r0 = mk(TAG_CTR, CID_QUA, nd); rn = 1u; sp -= 1; fid = stk_ld(0).x; }
      case FID_EXIT: { sp -= 2; let cont = stk_ld(0); let idx = stk_ld(1).x; deliver(cont, idx, r0); return; }
      default: { atomicStore(&ctl[ERR], 3u); return; }
    }
  }
}

// window_pix: descend the quadtree by the pixel's bits; a Pix ends the walk
// (upstream reads H[l + j] past a Pix at an inner level).
@compute @workgroup_size(64) fn raster(@builtin(global_invocation_id) g: vec3<u32>) {
  let id = g.x; if (id >= F.w * F.h) { return; }
  let x = id % F.w; let y = id / F.w;
  var t = vec2<u32>(atomicLoad(&ctl[ROOT]), atomicLoad(&ctl[ROOT + 1u]));
  var i = F.d;
  var guard = 0u;
  while (ttag(t) == TAG_CTR && guard < 32u) { guard += 1u;
    var j = 0u;
    if (taux(t) != CID_PIX && i > 0u) { i -= 1u; j = ((y >> i) & 1u) * 2u + ((x >> i) & 1u); }
    t = ld(t.x + j);
  }
  pix[id] = t.x & 0xFFFFFFu;
}
`;
const BLIT = `
struct Frame { k: u32, w: u32, h: u32, lanes: u32, d: u32, p0: u32, p1: u32, p2: u32, v: array<vec4<u32>, 4> }
@group(0) @binding(0) var<storage, read> pix: array<u32>;
@group(0) @binding(1) var<uniform> F: Frame;
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>, 3>(vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
  return vec4(p[i], 0.0, 1.0);
}
@fragment fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
  let x = u32(pos.x); let y = u32(pos.y);
  let c = pix[y * F.w + x];
  return vec4(f32((c >> 16u) & 255u) / 255.0, f32((c >> 8u) & 255u) / 255.0, f32(c & 255u) / 255.0, 1.0);
}`;

export async function start(prog, canvas) {
  const q = new URLSearchParams(location.search);
  const K = prog.K, W = prog.W, HH = prog.H;
  const G = Math.min(K, Math.max(1, Number(q.get("g") || prog.G)));
  const LANES = 4 ** G, DEPTH = 5 + 11 * (K - G), ND = 2 * G + 1;
  const leaves = 4 ** (K - G);
  const SLAB = { grow: 32, work: leaves * prog.leafSlots + (leaves - 1) / 3 * 4 + 8, join: 8 };
  const HEAP_SLOTS = 8 << 20;
  const a = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
  const feats = [...a.features].filter((x) => x === "timestamp-query");
  const d = await a.requestDevice({ requiredFeatures: feats, requiredLimits: { maxStorageBufferBindingSize: 1 << 30, maxBufferSize: 1 << 30, maxStorageBuffersPerShaderStage: 10 } });
  const errors = [];
  d.addEventListener("uncapturederror", (e) => { errors.push(e.error.message.split("\n")[0]); console.error("gpu:", e.error.message); });
  const ts = feats.length > 0;
  const B = (size, usage) => d.createBuffer({ size, usage });
  const Hb = B(HEAP_SLOTS * 8, GPUBufferUsage.STORAGE), stk = B(LANES * DEPTH * 8, GPUBufferUsage.STORAGE), pend = B(1 << 20, GPUBufferUsage.STORAGE);
  const ctl = B(256, GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC);
  const args = [0, 1, 2].map(() => B(256, GPUBufferUsage.STORAGE | GPUBufferUsage.INDIRECT));
  const Qb = B(3 * 262144 * 8, GPUBufferUsage.STORAGE), pix = B(W * HH * 4, GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC);
  const Pb = B(256 * (ND + 1), GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST), Fb = B(96, GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST);
  // a program's own words, read-only on the device (a world, a scene), written by setData
  const data = B(4 * Math.max(4, prog.dataWords || 0), GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST);
  const pv = new Uint32Array(64 * (ND + 1));
  for (let dd = 1; dd <= ND; dd++) { const mode = dd <= G ? 0 : dd === G + 1 ? 1 : 2; pv.set([mode, (dd - 1) % 3, dd % 3, (dd + 1) % 3, mode === 0 ? SLAB.grow : mode === 1 ? SLAB.work : SLAB.join], dd * 64); }
  d.queue.writeBuffer(Pb, 0, pv);
  const mod = d.createShaderModule({ code: RUNTIME.replace("//@PROGRAM", "const HEAP0: u32 = " + prog.heap0 + "u;\n" + prog.wgsl) });
  const info = await mod.getCompilationInfo();
  for (const m of info.messages) if (m.type === "error") throw new Error("WGSL " + m.lineNum + ":" + m.linePos + " " + m.message);
  const stor = (bnd) => ({ binding: bnd, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } });
  const base = [0, 1, 2, 3, 4, 6].map(stor).concat([{ binding: 5, visibility: GPUShaderStage.COMPUTE, buffer: { type: "uniform", hasDynamicOffset: true } }, { binding: 7, visibility: GPUShaderStage.COMPUTE, buffer: { type: "uniform" } }, { binding: 13, visibility: GPUShaderStage.COMPUTE, buffer: { type: "read-only-storage" } }]);
  const bglA = d.createBindGroupLayout({ entries: base.concat([10, 11, 12].map(stor)) });
  const bglB = d.createBindGroupLayout({ entries: base.concat([8, 9].map(stor)) });
  const pipe = (entryPoint, bgl) => d.createComputePipeline({ layout: d.createPipelineLayout({ bindGroupLayouts: [bgl] }), compute: { module: mod, entryPoint } });
  const pReset = pipe("reset", bglA), pRun = pipe("run", bglB), pRaster = pipe("raster", bglB);
  const ents = [{ binding: 0, resource: { buffer: Hb } }, { binding: 1, resource: { buffer: stk } }, { binding: 2, resource: { buffer: pend } }, { binding: 3, resource: { buffer: ctl } }, { binding: 4, resource: { buffer: Qb } }, { binding: 5, resource: { buffer: Pb, size: 256 } }, { binding: 6, resource: { buffer: pix } }, { binding: 7, resource: { buffer: Fb } }, { binding: 13, resource: { buffer: data } }];
  const bgA = d.createBindGroup({ layout: bglA, entries: ents.concat([10, 11, 12].map((bnd, i) => ({ binding: bnd, resource: { buffer: args[i] } }))) });
  const bgB = [0, 1, 2].map((rot) => d.createBindGroup({ layout: bglB, entries: ents.concat([{ binding: 8, resource: { buffer: args[rot] } }, { binding: 9, resource: { buffer: args[(rot + 1) % 3] } }]) }));
  const ctx = canvas.getContext("webgpu"), fmt = navigator.gpu.getPreferredCanvasFormat();
  canvas.width = W; canvas.height = HH;
  ctx.configure({ device: d, format: fmt });
  const bmod = d.createShaderModule({ code: BLIT });
  const bbgl = d.createBindGroupLayout({ entries: [{ binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "read-only-storage" } }, { binding: 1, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } }] });
  const pBlit = d.createRenderPipeline({ layout: d.createPipelineLayout({ bindGroupLayouts: [bbgl] }), vertex: { module: bmod, entryPoint: "vs" }, fragment: { module: bmod, entryPoint: "fs", targets: [{ format: fmt }] }, primitive: { topology: "triangle-list" } });
  const bbg = d.createBindGroup({ layout: bbgl, entries: [{ binding: 0, resource: { buffer: pix } }, { binding: 1, resource: { buffer: Fb } }] });
  const NQ = 64;
  const qs = ts ? d.createQuerySet({ type: "timestamp", count: 2 * NQ }) : null;
  const qres = ts ? B(16 * NQ, GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC) : null;
  const qread = ts ? B(16 * NQ, GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST) : null;
  const D = Math.log2(W);
  const setFrame = (words) => { const fv = new Uint32Array(24); fv[0] = K; fv[1] = W; fv[2] = HH; fv[3] = LANES; fv[4] = D; fv.set(words, 8); d.queue.writeBuffer(Fb, 0, fv); };
  const encode = (tsi, draw) => {
    const enc = d.createCommandEncoder();
    const pass = enc.beginComputePass(tsi >= 0 ? { timestampWrites: { querySet: qs, beginningOfPassWriteIndex: 2 * tsi, endOfPassWriteIndex: 2 * tsi + 1 } } : {});
    pass.setPipeline(pReset); pass.setBindGroup(0, bgA, [0]); pass.dispatchWorkgroups(1);
    pass.setPipeline(pRun);
    for (let dd = 1; dd <= ND; dd++) { pass.setBindGroup(0, bgB[dd % 3], [256 * dd]); pass.dispatchWorkgroupsIndirect(args[(dd - 1) % 3], 0); }
    pass.setPipeline(pRaster); pass.setBindGroup(0, bgB[0], [0]); pass.dispatchWorkgroups(Math.ceil(W * HH / 64));
    pass.end();
    if (draw) { const rp = enc.beginRenderPass({ colorAttachments: [{ view: ctx.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store" }] }); rp.setPipeline(pBlit); rp.setBindGroup(0, bbg); rp.draw(3); rp.end(); }
    return enc;
  };
  const readTimes = async (n) => {
    if (!ts) return null;
    const enc = d.createCommandEncoder(); enc.resolveQuerySet(qs, 0, 2 * n, qres, 0); enc.copyBufferToBuffer(qres, 0, qread, 0, 16 * n); d.queue.submit([enc.finish()]);
    await qread.mapAsync(GPUMapMode.READ); const v = new BigUint64Array(qread.getMappedRange()); const ms = []; for (let i = 0; i < n; i++) ms.push(Number(v[2 * i + 1] - v[2 * i]) / 1e6); qread.unmap();
    ms.sort((x, y) => x - y); return { min: +ms[0].toFixed(3), med: +ms[n >> 1].toFixed(3), max: +ms[n - 1].toFixed(3) };
  };
  return {
    device: d, G, ND, SLAB, LANES, DEPTH, errors, ts,
    setData(words, at = 0) { d.queue.writeBuffer(data, 4 * at, words); },
    // n frames back to back; GPU time of the compute pass, wall time per frame
    async burst(frames, n) {
      for (let i = 0; i < 3; i++) { setFrame(frames(i)); d.queue.submit([encode(-1, false).finish()]); }
      await d.queue.onSubmittedWorkDone();
      const t0 = performance.now();
      for (let i = 0; i < n; i++) { setFrame(frames(i)); d.queue.submit([encode(ts ? i % NQ : -1, false).finish()]); }
      await d.queue.onSubmittedWorkDone();
      const wall = (performance.now() - t0) / n;
      return { gpu_ms: await readTimes(Math.min(n, NQ)), wall_ms: +wall.toFixed(3) };
    },
    // one frame, read back
    async check(words) {
      setFrame(words);
      const enc = encode(-1, false); const cr = B(256, GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST), pr = B(W * HH * 4, GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST);
      enc.copyBufferToBuffer(ctl, 0, cr, 0, 256); enc.copyBufferToBuffer(pix, 0, pr, 0, W * HH * 4); d.queue.submit([enc.finish()]);
      await cr.mapAsync(GPUMapMode.READ); await pr.mapAsync(GPUMapMode.READ);
      const c = new Uint32Array(cr.getMappedRange()).slice(), p = new Uint32Array(pr.getMappedRange()).slice();
      cr.unmap(); pr.unmap();
      return { err: c[2], bump: c[0], heap_ok: c[0] < HEAP_SLOTS, joins: c[1], root: [c[20], c[21], c[22]], pixels: p };
    },
    // requestAnimationFrame loop; step(frameIndex) gives the frame's words
    live(step, onStats) {
      let frames = 0, i = 0, start = performance.now(), last = start, reading = false, gpu = null;
      const tick = () => { setFrame(step(i)); d.queue.submit([encode(ts ? i % NQ : -1, true).finish()]); frames++; i++; requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
      setInterval(async () => {
        const now = performance.now(), fps = frames / ((now - last) / 1000); frames = 0; last = now;
        if (ts && !reading && i >= NQ) { reading = true; try { gpu = await readTimes(NQ); } finally { reading = false; } }
        onStats({ fps: Math.round(fps), gpu });
      }, 1000);
    },
  };
}
