const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const repoRoot = path.resolve(__dirname, "..", "..");
const stageScript = path.join(repoRoot, "npm-pkgs", "scripts", "stage-npm-packages.js");
const { stagePackages } = require(stageScript);

const targets = [
  ["c2c-linux-x64", "linux", "x64", "c2c"],
  ["c2c-linux-arm64", "linux", "arm64", "c2c"],
  ["c2c-darwin-x64", "darwin", "x64", "c2c"],
  ["c2c-darwin-arm64", "darwin", "arm64", "c2c"],
  ["c2c-win32-x64", "win32", "x64", "c2c.exe"],
];

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "c2c-npm-stage-"));
}

function writeFakeBinaries(binaryRoot) {
  for (const [pkgDir, , , executable] of targets) {
    const file = path.join(binaryRoot, pkgDir, executable);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `${pkgDir}\n`, { mode: 0o755 });
    fs.chmodSync(file, 0o755);
  }
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

test("stage script creates meta and platform package directories", () => {
  const dir = tempDir();
  const binaryRoot = path.join(dir, "bin");
  const outDir = path.join(dir, "dist", "npm");
  writeFakeBinaries(binaryRoot);

  stagePackages({ version: "0.8.0", binaryRoot, outDir });

  const metaPackage = readJson(path.join(outDir, "c2c", "package.json"));
  assert.equal(metaPackage.name, "@clanker-code/c2c");
  assert.equal(metaPackage.version, "0.8.0");
  assert.equal(metaPackage.bin.c2c, "bin/c2c-js-wrapper.js");
  assert.deepEqual(metaPackage.files, ["bin/c2c-js-wrapper.js", "index.js"]);

  const optionalDependencyNames = Object.keys(metaPackage.optionalDependencies).sort();
  assert.deepEqual(optionalDependencyNames, targets.map(([pkgDir]) => `@clanker-code/${pkgDir}`).sort());
  assert.ok(fs.existsSync(path.join(outDir, "c2c", "index.js")));
  assert.ok(fs.existsSync(path.join(outDir, "c2c", "bin", "c2c-js-wrapper.js")));

  for (const [pkgDir, osName, cpuName, executable] of targets) {
    const packageJson = readJson(path.join(outDir, pkgDir, "package.json"));
    assert.equal(packageJson.name, `@clanker-code/${pkgDir}`);
    assert.equal(packageJson.version, "0.8.0");
    assert.deepEqual(packageJson.os, [osName]);
    assert.deepEqual(packageJson.cpu, [cpuName]);
    assert.deepEqual(packageJson.files, [`bin/${executable}`]);
    assert.equal(packageJson.bin.c2c, `bin/${executable}`);
    assert.equal(fs.readFileSync(path.join(outDir, pkgDir, "bin", executable), "utf8"), `${pkgDir}\n`);
  }
});

test("stage script refuses to create packages when a required binary is missing", () => {
  const dir = tempDir();
  const binaryRoot = path.join(dir, "bin");
  const outDir = path.join(dir, "dist", "npm");
  writeFakeBinaries(binaryRoot);
  fs.rmSync(path.join(binaryRoot, "c2c-darwin-arm64"), { recursive: true, force: true });

  assert.throws(
    () => stagePackages({ version: "0.8.0", binaryRoot, outDir }),
    /missing required binary.*c2c-darwin-arm64/s
  );
});
