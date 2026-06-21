"use strict";

const fs = require("node:fs");
const path = require("node:path");

const TARGETS = {
  "linux-x64": {
    packageName: "@clanker-code/c2c-linux-x64",
  },
  "linux-arm64": {
    packageName: "@clanker-code/c2c-linux-arm64",
  },
  "darwin-x64": {
    packageName: "@clanker-code/c2c-darwin-x64",
  },
  "darwin-arm64": {
    packageName: "@clanker-code/c2c-darwin-arm64",
  },
};

const EXECUTABLES = new Set(["c2c", "c2c-deliver-inbox"]);

function normalizeExecutable(executable = "c2c") {
  if (!EXECUTABLES.has(executable)) {
    throw new Error(`unsupported c2c executable: ${executable}`);
  }
  return executable;
}

function envOverrideName(executable) {
  return executable === "c2c-deliver-inbox" ? "C2C_DELIVER_INBOX_BIN" : "C2C_BIN";
}

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

function pathCandidates(env, platform, executable) {
  const pathValue = env.PATH || "";
  const dirs = pathValue.split(path.delimiter).filter(Boolean);
  const names =
    platform === "win32"
      ? [`${executable}.exe`, `${executable}.cmd`, `${executable}.bat`, executable]
      : [executable];

  return dirs.flatMap((dir) => names.map((name) => path.join(dir, name)));
}

function looksLikeSelfNpmShim(candidate, selfPath) {
  if (!candidate.match(/\.(cmd|bat)$/i)) {
    return false;
  }

  try {
    const body = fs.readFileSync(candidate, "utf8");
    const normalizedBody = body.replace(/\\/g, "/").toLowerCase();
    const normalizedSelf = selfPath.replace(/\\/g, "/").toLowerCase();
    return normalizedBody.includes(normalizedSelf) || normalizedBody.includes("c2c-js-wrapper.js");
  } catch {
    return false;
  }
}

function findSystemExecutable(env, selfPath, platform, executable) {
  for (const candidate of pathCandidates(env, platform, executable)) {
    if (canExecute(candidate) && !sameFile(candidate, selfPath) && !looksLikeSelfNpmShim(candidate, selfPath)) {
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

function resolvePlatformPackage(target, requireFrom, executable) {
  try {
    const packageJson = require.resolve(`${target.packageName}/package.json`, {
      paths: [requireFrom],
    });
    return path.join(path.dirname(packageJson), "bin", executable);
  } catch (error) {
    const directRoot = findDirectPackageRoot(requireFrom, target, executable);
    if (directRoot) {
      return path.join(directRoot, "bin", executable);
    }
    throw error;
  }
}

function findDirectPackageRoot(requireFrom, target, executable) {
  let current = path.resolve(requireFrom);
  const parts = target.packageName.split("/");

  while (true) {
    const candidate = path.join(current, "node_modules", ...parts);
    const bin = path.join(candidate, "bin", executable);
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
  const executable = normalizeExecutable(options.executable || "c2c");
  const env = options.env || process.env;
  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  const requireFrom = options.requireFrom || __dirname;
  const selfPath = options.selfPath || path.join(__dirname, "bin", "c2c-js-wrapper.js");
  const overrideName = envOverrideName(executable);

  if (env[overrideName]) {
    if (!canExecute(env[overrideName])) {
      throw new Error(`${overrideName} is set but is not executable: ${env[overrideName]}`);
    }
    return env[overrideName];
  }

  const target = platformTarget(platform, arch);
  let platformError = null;

  if (target) {
    try {
      const resolved = resolvePlatformPackage(target, requireFrom, executable);
      if (canExecute(resolved)) {
        return resolved;
      }
      throw new Error(`resolved package binary is not executable: ${resolved}`);
    } catch (error) {
      platformError = error;
    }
  }

  const systemExecutable = findSystemExecutable(env, selfPath, platform, executable);
  if (systemExecutable) {
    return systemExecutable;
  }

  if (!target) {
    throw new Error(
      `No c2c npm binary package is available for ${platform}-${arch}. ` +
        `Install ${executable} system-wide, choose a supported platform, or set ${overrideName} to a ${executable} executable.`
    );
  }

  throw new Error(
    `Unable to find executable ${executable} in ${target.packageName} for ${platform}-${arch}. ` +
      `Install @clanker-code/c2c with optional dependencies enabled, install ${executable} system-wide, or set ${overrideName}. ` +
      `Cause: ${platformError.message}`
  );
}

module.exports = {
  resolveC2cBinary,
  _platformPackageName: platformPackageName,
};
