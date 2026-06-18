#!/usr/bin/env node
"use strict";

const childProcess = require("node:child_process");
const { resolveC2cBinary } = require("..");

function main() {
  let binary;
  try {
    binary = resolveC2cBinary({ selfPath: __filename });
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }

  const result = childProcess.spawnSync(binary, process.argv.slice(2), {
    stdio: "inherit",
    env: process.env,
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

main();
