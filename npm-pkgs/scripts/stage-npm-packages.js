#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const TARGETS = [
  { dir: "c2c-linux-x64", os: "linux", cpu: "x64", executable: "c2c" },
  { dir: "c2c-linux-arm64", os: "linux", cpu: "arm64", executable: "c2c" },
  { dir: "c2c-darwin-x64", os: "darwin", cpu: "x64", executable: "c2c" },
  { dir: "c2c-darwin-arm64", os: "darwin", cpu: "arm64", executable: "c2c" },
];

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name || !name.startsWith("--") || !value) {
      throw new Error("usage: stage-npm-packages.js --version X.Y.Z --binary-root DIR --out-dir DIR");
    }
    options[name.slice(2)] = value;
  }

  for (const required of ["version", "binary-root", "out-dir"]) {
    if (!options[required]) {
      throw new Error(`missing required option --${required}`);
    }
  }

  return {
    version: options.version,
    binaryRoot: path.resolve(options["binary-root"]),
    outDir: path.resolve(options["out-dir"]),
  };
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function copyExecutable(src, dst) {
  if (!fs.existsSync(src)) {
    throw new Error(`missing required binary: ${src}`);
  }

  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
  if (process.platform !== "win32") {
    fs.chmodSync(dst, 0o755);
  }
}

function isSameOrInside(candidate, parent) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function pathsOverlap(left, right) {
  return isSameOrInside(left, right) || isSameOrInside(right, left);
}

function assertNoSymlinkComponents(targetPath) {
  const resolvedTarget = path.resolve(targetPath);
  const root = path.parse(resolvedTarget).root;
  const relativeParts = path.relative(root, resolvedTarget).split(path.sep).filter(Boolean);
  let current = root;

  for (const part of relativeParts) {
    current = path.join(current, part);
    try {
      if (fs.lstatSync(current).isSymbolicLink()) {
        throw new Error(`refusing unsafe --out-dir: ${resolvedTarget} contains symlink component ${current}`);
      }
    } catch (error) {
      if (error.code === "ENOENT") {
        return;
      }
      throw error;
    }
  }
}

function assertSafeOutDir({ outDir, binaryRoot, sourceRoot = path.resolve(__dirname, "..") }) {
  const resolvedOutDir = path.resolve(outDir);
  const resolvedBinaryRoot = path.resolve(binaryRoot);
  const resolvedSourceRoot = path.resolve(sourceRoot);
  const unsafeRoots = [path.parse(resolvedOutDir).root, os.homedir()].filter(Boolean);

  if (unsafeRoots.includes(resolvedOutDir)) {
    throw new Error(`refusing unsafe --out-dir: ${resolvedOutDir}`);
  }

  if (path.basename(path.dirname(resolvedOutDir)) !== "dist" || path.basename(resolvedOutDir) !== "npm") {
    throw new Error(`refusing unsafe --out-dir: ${resolvedOutDir} must end with dist/npm`);
  }

  assertNoSymlinkComponents(resolvedOutDir);

  if (pathsOverlap(resolvedOutDir, resolvedSourceRoot)) {
    throw new Error(`refusing unsafe --out-dir: ${resolvedOutDir} overlaps source tree ${resolvedSourceRoot}`);
  }

  if (pathsOverlap(resolvedOutDir, resolvedBinaryRoot)) {
    throw new Error(`refusing unsafe --out-dir: ${resolvedOutDir} overlaps binary root ${resolvedBinaryRoot}`);
  }
}

function optionalDependencies(version) {
  return Object.fromEntries(
    TARGETS.map((target) => [`@clanker-code/${target.dir}`, version])
  );
}

function stageMetaPackage({ version, outDir }) {
  const sourceRoot = path.resolve(__dirname, "..", "c2c");
  const packageDir = path.join(outDir, "c2c");

  fs.mkdirSync(path.join(packageDir, "bin"), { recursive: true });
  fs.copyFileSync(path.join(sourceRoot, "index.js"), path.join(packageDir, "index.js"));
  fs.copyFileSync(
    path.join(sourceRoot, "bin", "c2c-js-wrapper.js"),
    path.join(packageDir, "bin", "c2c-js-wrapper.js")
  );
  fs.chmodSync(path.join(packageDir, "bin", "c2c-js-wrapper.js"), 0o755);

  writeJson(path.join(packageDir, "package.json"), {
    name: "@clanker-code/c2c",
    version,
    description: "c2c CLI resolver and npm binary-package wrapper",
    license: "MIT",
    type: "commonjs",
    main: "index.js",
    bin: { c2c: "bin/c2c-js-wrapper.js" },
    files: ["bin/c2c-js-wrapper.js", "index.js"],
    optionalDependencies: optionalDependencies(version),
  });
}

function stagePlatformPackage({ version, binaryRoot, outDir, target }) {
  const packageDir = path.join(outDir, target.dir);
  const binarySrc = path.join(binaryRoot, target.dir, target.executable);
  const binaryDst = path.join(packageDir, "bin", target.executable);

  copyExecutable(binarySrc, binaryDst);
  writeJson(path.join(packageDir, "package.json"), {
    name: `@clanker-code/${target.dir}`,
    version,
    description: `c2c CLI binary for ${target.os}-${target.cpu}`,
    license: "MIT",
    os: [target.os],
    cpu: [target.cpu],
    files: [`bin/${target.executable}`],
    bin: { c2c: `bin/${target.executable}` },
  });
}

function stagePackages(options) {
  assertSafeOutDir(options);
  fs.rmSync(options.outDir, { recursive: true, force: true });
  fs.mkdirSync(options.outDir, { recursive: true });
  stageMetaPackage(options);
  for (const target of TARGETS) {
    stagePlatformPackage({ ...options, target });
  }
}

function main() {
  try {
    const options = parseArgs(process.argv.slice(2));
    stagePackages(options);
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  TARGETS,
  assertSafeOutDir,
  stagePackages,
};
