import esbuild from "esbuild";
import fs from "fs";
import path from "path";

const outdir = "dist";
const entryPoints = ["src/background.js", "src/popup.js", "src/options.js"];
const manifestFile = process.env.MANIFEST_FILE || "manifest.json";

fs.rmSync(outdir, { recursive: true, force: true });
fs.mkdirSync(outdir, { recursive: true });

const common = {
  bundle: true,
  sourcemap: false,
  format: "esm",
  target: ["es2020"],
  outdir,
  external: ["./wasm_crypto.js"], // Don't bundle WASM module
  loader: {
    ".png": "file",
    ".wasm": "file"
  },
};

await esbuild.build({
  ...common,
  entryPoints,
});

// Copy static files
for (const file of [
  manifestFile,
  'src/background.html',
  'src/popup.html',
  'src/options.html',
  'src/popup.css',
  'src/options.css',
  'src/icon.png',
  'icon/pushstr_48.png',
  'icon/pushstr_96.png',
  'icon/pushstr_128.png',
]) {
  const dest = path.join(
    outdir,
    path.basename(file === manifestFile ? 'manifest.json' : file),
  );
  fs.copyFileSync(file, dest);
}

// Copy WASM files to dist root (background.js is bundled to dist/background.js)
fs.copyFileSync("src/wasm_crypto.js", path.join(outdir, "wasm_crypto.js"));
fs.copyFileSync("src/wasm_crypto_bg.wasm", path.join(outdir, "wasm_crypto_bg.wasm"));

// Copy vendor bundle
fs.cpSync("vendor", path.join(outdir, "vendor"), { recursive: true });

console.log("Build complete ->", outdir);
