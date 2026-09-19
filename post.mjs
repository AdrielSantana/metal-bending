// post.mjs <pages dir>: on the demos that exist both as a CPU (wasm) page and a WebGPU page,
// the thread selector gains a "WebGPU" entry and the WebGPU page gains the same selector,
// so one control switches between the two runtimes. Idempotent.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const dir = process.argv[2];
const pairs = [
  ["mandelbrot.html", "gpu_mandelbrot.html"],
  ["04_voxel_fast.html", "gpu_voxel.html"],
  ["app_ray_tracer_3d.html", "gpu_raytracer.html"],
  ["raytracer_512.html", "gpu_raytracer.html?res=512"],
];
const MARK = "<!-- mode selector -->";
const edit = (name, fn) => { const p = join(dir, name); const s = readFileSync(p, "utf8"); if (s.includes(MARK)) return "kept " + name; writeFileSync(p, fn(s)); return "edited " + name; };
for (const [cpu, gpu] of pairs) {
  console.log(edit(cpu, (s) => {
    const line = '<pre><select id="bend-threads"></select> threads, <span id="bend-rate"></span></pre>';
    if (!s.includes(line)) throw new Error(cpu + ": selector line not found");
    return s.replace(line, '<pre>on <select id="bend-threads"></select>, <span id="bend-rate"></span></pre>')
      .replace('<script src="coi-serviceworker.js"></script>', `${MARK}
<script>
  // this demo also runs on WebGPU (${gpu.replace(/\?.*/, "")}); the same selector switches to it
  for (var o = 0; o < select.options.length; o += 1) {
    select.options[o].text = select.options[o].value + (select.options[o].value == 1 ? " thread" : " threads");
  }
  select.appendChild(new Option("WebGPU", "gpu"));
  select.onchange = function() {
    location.href = select.value == "gpu" ? "${gpu}" : "?threads=" + select.value;
  };
</script>
<script src="coi-serviceworker.js"></script>`);
  }));
}
const gpuPages = {
  "gpu_mandelbrot.html": '"mandelbrot.html"',
  "gpu_voxel.html": '"04_voxel_fast.html"',
  "gpu_raytracer.html": 'new URLSearchParams(location.search).get("res") == "512" ? "raytracer_512.html" : "app_ray_tracer_3d.html"',
};
for (const [name, cpuExpr] of Object.entries(gpuPages)) {
  console.log(edit(name, (s) => {
    const line = '<pre id="bend-fps">starting on the GPU…</pre>';
    if (!s.includes(line)) throw new Error(name + ": fps line not found");
    return s.replace("</style>", "select{font:inherit;color:inherit;background:#222;border:1px solid #444}</style>")
      .replace(line, `<pre>on <select id="bend-threads"></select>, <span id="bend-fps">starting on the GPU…</span></pre>${MARK}
<script>
  // the same selector as the CPU page: the threads entries go back to it
  var select = document.getElementById("bend-threads"), cores = navigator.hardwareConcurrency;
  select.appendChild(new Option("WebGPU", "gpu"));
  for (var i = 1; i <= cores; i += 1) select.appendChild(new Option(i + (i == 1 ? " thread" : " threads"), i));
  select.onchange = function() { if (select.value != "gpu") location.href = (${cpuExpr}) + "?threads=" + select.value; };
</script>`);
  }));
}
