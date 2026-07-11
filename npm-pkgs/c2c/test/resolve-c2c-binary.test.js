const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const packageRoot = path.resolve(__dirname, "..");
const wrapperPath = path.join(packageRoot, "bin", "c2c-js-wrapper.js");
const deliverWrapperPath = path.join(packageRoot, "bin", "c2c-deliver-inbox-js-wrapper.js");

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "c2c-npm-resolver-"));
}

function makeExecutable(file, body = "#!/bin/sh\nexit 0\n") {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body, { mode: 0o755 });
  fs.chmodSync(file, 0o755);
  return file;
}

function loadResolver() {
  delete require.cache[require.resolve("../index.js")];
  return require("../index.js");
}

function loadWrapper() {
  delete require.cache[require.resolve("../bin/c2c-js-wrapper.js")];
  return require("../bin/c2c-js-wrapper.js");
}

test("C2C_BIN wins over PATH and platform package fallback", () => {
  const dir = tempDir();
  const explicit = makeExecutable(path.join(dir, "custom-c2c"));
  const pathBin = makeExecutable(path.join(dir, "path", "c2c"));
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    env: { C2C_BIN: explicit, PATH: path.dirname(pathBin) },
    platform: "linux",
    arch: "x64",
    requireFrom: path.join(dir, "missing-root"),
  });

  assert.equal(resolved, explicit);
});

test("C2C_DELIVER_INBOX_BIN wins for deliver-inbox", () => {
  const dir = tempDir();
  const explicit = makeExecutable(path.join(dir, "custom-deliver-inbox"));
  const platformDeliver = makeExecutable(
    path.join(dir, "node_modules", "@clanker-code", "c2c-linux-x64", "bin", "c2c-deliver-inbox")
  );
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    executable: "c2c-deliver-inbox",
    env: { C2C_DELIVER_INBOX_BIN: explicit, PATH: "" },
    platform: "linux",
    arch: "x64",
    requireFrom: path.dirname(path.dirname(path.dirname(platformDeliver))),
  });

  assert.equal(resolved, explicit);
});

test("C2C_BIN must point at an executable file", () => {
  const dir = tempDir();
  const explicit = path.join(dir, "not-executable");
  fs.writeFileSync(explicit, "nope\n", { mode: 0o644 });
  const { resolveC2cBinary } = loadResolver();

  assert.throws(
    () => resolveC2cBinary({ env: { C2C_BIN: explicit, PATH: "" } }),
    /C2C_BIN is set but is not executable/
  );
});

test("npm platform deliver-inbox is used before system deliver-inbox on PATH", () => {
  const dir = tempDir();
  const systemDeliver = makeExecutable(path.join(dir, "bin", "c2c-deliver-inbox"));
  const platformDeliver = makeExecutable(
    path.join(dir, "node_modules", "@clanker-code", "c2c-linux-x64", "bin", "c2c-deliver-inbox")
  );
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    executable: "c2c-deliver-inbox",
    env: { PATH: path.dirname(systemDeliver) },
    platform: "linux",
    arch: "x64",
    requireFrom: path.dirname(path.dirname(path.dirname(platformDeliver))),
  });

  assert.equal(resolved, platformDeliver);
});

test("npm platform package is used before system c2c on PATH", () => {
  const dir = tempDir();
  const systemC2c = makeExecutable(path.join(dir, "bin", "c2c"));
  const platformC2c = makeExecutable(
    path.join(dir, "node_modules", "@clanker-code", "c2c-linux-x64", "bin", "c2c")
  );
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    env: { PATH: path.dirname(systemC2c) },
    platform: "linux",
    arch: "x64",
    requireFrom: path.dirname(path.dirname(path.dirname(platformC2c))),
  });

  assert.equal(resolved, platformC2c);
});

test("system c2c on PATH is fallback when platform package is missing", () => {
  const dir = tempDir();
  const systemC2c = makeExecutable(path.join(dir, "bin", "c2c"));
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    env: { PATH: path.dirname(systemC2c) },
    platform: "linux",
    arch: "x64",
    requireFrom: path.join(dir, "missing-root"),
  });

  assert.equal(resolved, systemC2c);
});

test("PATH lookup ignores the npm wrapper currently resolving itself", () => {
  const dir = tempDir();
  const pathWrapper = makeExecutable(path.join(dir, "bin", "c2c"));
  const platformC2c = makeExecutable(
    path.join(dir, "node_modules", "@clanker-code", "c2c-linux-x64", "bin", "c2c")
  );
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    env: { PATH: path.dirname(pathWrapper) },
    platform: "linux",
    arch: "x64",
    selfPath: pathWrapper,
    requireFrom: path.join(dir, "node_modules", "@clanker-code", "c2c"),
  });

  assert.equal(resolved, platformC2c);
});

test("matching platform package is used when PATH has no c2c", () => {
  const dir = tempDir();
  const platformC2c = makeExecutable(
    path.join(dir, "node_modules", "@clanker-code", "c2c-darwin-arm64", "bin", "c2c")
  );
  const { resolveC2cBinary } = loadResolver();

  const resolved = resolveC2cBinary({
    env: { PATH: "" },
    platform: "darwin",
    arch: "arm64",
    requireFrom: path.join(dir, "node_modules", "@clanker-code", "c2c"),
  });

  assert.equal(resolved, platformC2c);
});

test("unsupported platforms fail with actionable guidance", () => {
  const { resolveC2cBinary } = loadResolver();

  assert.throws(
    () => resolveC2cBinary({ env: { PATH: "" }, platform: "freebsd", arch: "riscv64" }),
    /No c2c npm binary package is available for freebsd-riscv64.*C2C_BIN/s
  );
});

test("deliver-inbox wrapper forwards to c2c-deliver-inbox binary", () => {
  const dir = tempDir();
  const log = path.join(dir, "deliver-argv.log");
  const fakeDeliver = makeExecutable(
    path.join(dir, "fake-deliver-inbox"),
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${log}"\nexit 19\n`
  );
  const result = childProcess.spawnSync(
    process.execPath,
    [deliverWrapperPath, "--full-body", "--register"],
    {
      env: { ...process.env, C2C_DELIVER_INBOX_BIN: fakeDeliver, PATH: "" },
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 19);
  assert.equal(fs.readFileSync(log, "utf8"), "--full-body\n--register\n");
});

test("wrapper forwards arguments and exits with child status", () => {
  const dir = tempDir();
  const log = path.join(dir, "argv.log");
  const fakeC2c = makeExecutable(
    path.join(dir, "fake-c2c"),
    `#!/bin/sh\nprintf '%s\\n' "$@" > "${log}"\nexit 17\n`
  );

  const result = childProcess.spawnSync(
    process.execPath,
    [wrapperPath, "--version", "--probe"],
    {
      env: { ...process.env, C2C_BIN: fakeC2c, PATH: "" },
      encoding: "utf8",
    }
  );

  assert.equal(result.status, 17);
  assert.equal(fs.readFileSync(log, "utf8"), "--version\n--probe\n");
});

test("wrapper selects npm, pnpm, and Bun package managers", () => {
  const { packageManagerForWrapper } = loadWrapper();
  const wrapper = "/opt/lib/node_modules/@clanker-code/c2c/bin/c2c-js-wrapper.js";

  assert.equal(packageManagerForWrapper(wrapper, { npm_config_user_agent: "npm/11.0.0 node/v22" }), "npm");
  assert.equal(packageManagerForWrapper(wrapper, { npm_config_user_agent: "pnpm/10.0.0 npm/?" }), "pnpm");
  assert.equal(packageManagerForWrapper(wrapper, { npm_config_user_agent: "bun/1.2.0 npm/?" }), "bun");
});

test("wrapper recognizes a Windows Bun global-install path", () => {
  const { packageManagerForWrapper } = loadWrapper();
  assert.equal(
    packageManagerForWrapper(
      "C:\\Users\\agent\\.bun\\install\\global\\node_modules\\@clanker-code\\c2c\\bin\\c2c-js-wrapper.js",
      {}
    ),
    "bun"
  );
});

test("wrapper passes selected package manager to the native c2c process", () => {
  const dir = tempDir();
  const log = path.join(dir, "package-manager.log");
  const fakeC2c = makeExecutable(
    path.join(dir, "fake-c2c"),
    `#!/bin/sh\nprintf '%s' "$C2C_SELF_UPDATE_PACKAGE_MANAGER" > "${log}"\n`
  );

  const result = childProcess.spawnSync(process.execPath, [wrapperPath, "self-update"], {
    env: {
      ...process.env,
      C2C_BIN: fakeC2c,
      PATH: "",
      npm_config_user_agent: "pnpm/10.0.0 npm/?",
    },
    encoding: "utf8",
  });

  assert.equal(result.status, 0);
  assert.equal(fs.readFileSync(log, "utf8"), "pnpm");
});
