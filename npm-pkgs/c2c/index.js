"use strict";

const fs = require("node:fs");
const path = require("node:path");

const TARGETS = {
  "linux-x64": {
    packageName: "@clanker-code/c2c-linux-x64",
    executable: "c2c",
  },
  "linux-arm64": {
    packageName: "@clanker-code/c2c-linux-arm64",
    executable: "c2c",
  },
  "darwin-x64": {
    packageName: "@clanker-code/c2c-darwin-x64",
    executable: "c2c",
  },
  "darwin-arm64": {
    packageName: "@clanker-code/c2c-darwin-arm64",
    executable: "c2c",
  },
  "win32-x64": {
    packageName: "@clanker-code/c2c-win32-x64",
    executable: "c2c.exe",
  },
};

function canExecute(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function sameFile(left, right) {
  if (!left || !right) {
    return false;
  }

  try {
    return fs.realpathSync(left) === fs.realpathSync(right);
  } catch {
    return path.resolve(left) === path.resolve(right);
  }
}

function pathCandidates(env) {
  const pathValue = env.PATH || "";
  const dirs = pathValue.split(path.delimiter).filter(Boolean);
  const names =
    process.platform === "win32"
      ? ["c2c.exe", "c2c.cmd", "c2c.bat", "c2c"]
      : ["c2c"];

  return dirs.flatMap((dir) => names.map((name) => path.join(dir, name)));
}

function findSystemC2c(env, selfPath) {
  for (const candidate of pathCandidates(env)) {
    if (canExecute(candidate) && !sameFile(candidate, selfPath)) {
      return candidate;
    }
  }
  return null;
}

function platformTarget(platform, arch) {
  return TARGETS[`${platform}-${arch}`] || null;
}

function platformPackageName(platform = process.platform, arch = process.arch) {
  const target = platformTarget(platform, arch);
  return target ? target.packageName : null;
}

function resolvePlatformPackage(target, requireFrom) {
  try {
    const packageJson = require.resolve(`${target.packageName}/package.json`, {
      paths: [requireFrom],
    });
    return path.join(path.dirname(packageJson), "bin", target.executable);
  } catch (error) {
    const directRoot = findDirectPackageRoot(requireFrom, target);
    if (directRoot) {
      return path.join(directRoot, "bin", target.executable);
    }
    throw error;
  }
}

function findDirectPackageRoot(requireFrom, target) {
  let current = path.resolve(requireFrom);
  const parts = target.packageName.split("/");

  while (true) {
    const candidate = path.join(current, "node_modules", ...parts);
    const bin = path.join(candidate, "bin", target.executable);
    if (fs.existsSync(bin)) {
      return candidate;
    }

    const next = path.dirname(current);
    if (next === current) {
      return null;
    }
    current = next;
  }
}

function resolveC2cBinary(options = {}) {
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  const requireFrom = options.requireFrom || __dirname;
  const selfPath = options.selfPath || path.join(__dirname, "bin", "c2c-js-wrapper.js");

  if (env.C2C_BIN) {
    if (!canExecute(env.C2C_BIN)) {
      throw new Error(`C2C_BIN is set but is not executable: ${env.C2C_BIN}`);
    }
    return env.C2C_BIN;
  }

  const systemC2c = findSystemC2c(env, selfPath);
  if (systemC2c) {
    return systemC2c;
  }

  const target = platformTarget(platform, arch);
  if (!target) {
    throw new Error(
      `No c2c npm binary package is available for ${platform}-${arch}. ` +
        "Install c2c system-wide, choose a supported platform, or set C2C_BIN to a c2c executable."
    );
  }

  try {
    const resolved = resolvePlatformPackage(target, requireFrom);
    if (canExecute(resolved)) {
      return resolved;
    }
    throw new Error(`resolved package binary is not executable: ${resolved}`);
  } catch (error) {
    throw new Error(
      `Unable to find executable ${target.packageName} for ${platform}-${arch}. ` +
        `Install @clanker-code/c2c with optional dependencies enabled, install c2c system-wide, or set C2C_BIN. ` +
        `Cause: ${error.message}`
    );
  }
}

module.exports = {
  resolveC2cBinary,
  _platformPackageName: platformPackageName,
};
