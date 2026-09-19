// shared page glue: runs the burst, the check against the JS reference, then the live loop
import { start } from "./rt.js";
export async function page(prog) {
  const $ = (id) => document.getElementById(id);
  const q = new URLSearchParams(location.search), NF = Number(q.get("n") || 40);
  try {
    const rt = await start(prog, $("bend"));
    const burst = await rt.burst(prog.frames, NF);
    const words = prog.frames(0);
    const c = await rt.check(words);
    let mism = 0, close = 0, sum = 0, bad = [];
    const N = prog.W * prog.H;
    if (prog.ref) for (let y = 0; y < prog.H; y++) for (let x = 0; x < prog.W; x++) {
      const got = c.pixels[y * prog.W + x], want = prog.ref(x, y, words) >>> 0; sum = (sum + got) >>> 0;
      if (got !== want) { const dr = Math.abs((got >> 16) - (want >> 16)), dg = Math.abs((got >> 8 & 255) - (want >> 8 & 255)), db = Math.abs((got & 255) - (want & 255));
        if (dr + dg + db <= 6) close++; else { if (bad.length < 4) bad.push([x, y, got.toString(16), want.toString(16)]); mism++; } }
    }
    { const sc = document.createElement("canvas"); sc.id = "snap"; sc.width = prog.W; sc.height = prog.H; sc.style.display = "none"; document.body.appendChild(sc);
      const im = new ImageData(prog.W, prog.H); for (let i = 0; i < N; i++) { const v = c.pixels[i]; im.data[4 * i] = v >> 16 & 255; im.data[4 * i + 1] = v >> 8 & 255; im.data[4 * i + 2] = v & 255; im.data[4 * i + 3] = 255; }
      sc.getContext("2d").putImageData(im, 0, 0); }
    window.__result = { name: prog.name, res: prog.W + "x" + prog.H, g: rt.G, dispatches: rt.ND + 2, ...burst, err: c.err, heap_ok: c.heap_ok, bump: c.bump, joins: c.joins, root_tag: (c.root[1] >>> 24) & 127, done: c.root[2], mismatches: mism, near: close, of: N, bad, checksum: sum, slab: rt.SLAB, lanes: rt.LANES, depth: rt.DEPTH, errors: rt.errors };
    $("bend-out").textContent = JSON.stringify(window.__result);
    rt.live(prog.live || prog.frames, (s) => { $("bend-fps").textContent = s.fps + " fps" + (s.gpu ? " · GPU " + s.gpu.med + " ms/frame (" + s.gpu.min + "–" + s.gpu.max + ")" : "") + " · " + rt.G + " fork levels on " + rt.LANES + " lanes"; window.__frames = (window.__frames | 0) + s.fps; prog.onStats?.(s); });
  } catch (e) { window.__result = { error: String(e), stack: e.stack }; $("bend-fps").textContent = navigator.gpu ? "GPU error" : "no WebGPU here"; $("bend-out").textContent = navigator.gpu ? String(e) : "This browser exposes no WebGPU. Chrome 113+, Edge 113+, Safari 26 and Firefox 141+ do; the CPU pages on the index run everywhere."; }
}
