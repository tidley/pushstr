import fs from "fs";
import path from "path";

const targets = ["src/wasm_crypto.js", "dist/wasm_crypto.js"];

const pattern =
  /(imports\.wbg\.__wbg_new_no_args_[^=]*=)\s*function\([^)]*\)\s*\{\s*const ret = new Function\(getStringFromWasm0\([^)]*\)\);\s*return ret;\s*\};/s;

const replacement =
  `$1 function() { throw new Error("Dynamic code evaluation is disabled in Pushstr builds."); };`;

function patchFile(filePath) {
  if (!fs.existsSync(filePath)) return false;
  const original = fs.readFileSync(filePath, "utf8");
  const patched = original.replace(pattern, replacement);

  if (patched === original) {
    return false;
  }

  if (patched.includes("new Function(")) {
    throw new Error(
      `Failed to remove Function constructor usage in ${filePath}`,
    );
  }

  fs.writeFileSync(filePath, patched, "utf8");
  return true;
}

const results = targets.map((target) => {
  const patched = patchFile(target);
  return { target, patched };
});

const patchedAny = results.some((r) => r.patched);
if (patchedAny) {
  const patchedList = results
    .filter((r) => r.patched)
    .map((r) => r.target)
    .join(", ");
  console.log(`Patched wasm glue: ${patchedList}`);
} else {
  console.log("No wasm glue patch needed.");
}
