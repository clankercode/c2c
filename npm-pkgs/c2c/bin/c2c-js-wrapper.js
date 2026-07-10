#!/usr/bin/env node
"use strict";

const path = require("node:path");
const childProcess = require("node:child_process");
const { resolveC2cBinary } = require("..");

function executableForWrapper(argv1) {
  const basename = path.basename(argv1 || "c2c");
  return basename.startsWith("c2c-deliver-inbox") ? "c2c-deliver-inbox" : "c2c";
}

function packageManagerForWrapper(selfPath, env = process.env) {
  const userAgent = env.npm_config_user_agent || "";
  if (userAgent.startsWith("pnpm/")) {
    return "pnpm";
  }
  if (userAgent.startsWith("bun/")) {
    return "bun";
  }

  const normalizedPath = selfPath.replace(/\\/g, "/").toLowerCase();
  if (normalizedPath.includes("/.bun/install/global/")) {
    return "bun";
  }
  if (normalizedPath.includes("/pnpm/global/")) {
    return "pnpm";
  }
  return "npm";
}

function main() {
  const executable = executableForWrapper(process.argv[1]);
  let binary;
  try {
    binary = resolveC2cBinary({ selfPath: __filename, executable });
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }

  const result = childProcess.spawnSync(binary, process.argv.slice(2), {
    stdio: "inherit",
    // The native binary cannot otherwise tell that it was launched by this
    // npm package wrapper.  Preserve the owning package manager so
    // `c2c self-update` upgrades the package instead of replacing the bundled
    // binary under node_modules.
    env: {
      ...process.env,
      C2C_SELF_UPDATE_PACKAGE_MANAGER: packageManagerForWrapper(__filename),
    },
  });

  if (result.error) {
    console.error(`failed to execute ${binary}: ${result.error.message}`);
    process.exit(1);
  }

  if (result.signal) {
    process.kill(process.pid, result.signal);
    process.exit(1);
  }

  process.exit(result.status === null ? 1 : result.status);
}

if (require.main === module) {
  main();
}

module.exports = { executableForWrapper, packageManagerForWrapper, main };
