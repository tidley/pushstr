import fs from "fs";
import path from "path";
import { execSync } from "child_process";

const outdir = "dist";
const zipPath = "pushstr.zip";

if (!fs.existsSync(outdir)) {
  console.error("dist/ not found. Run npm run build first.");
  process.exit(1);
}

try {
  fs.rmSync(zipPath, { force: true });
} catch (_) {}

const cwd = process.cwd();
const cmd = `cd ${outdir} && zip -r ../${zipPath} .`;
execSync(cmd, { stdio: "inherit", cwd });
console.log(`Packaged ${zipPath}`);
