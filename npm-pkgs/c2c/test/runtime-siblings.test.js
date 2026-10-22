const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
test('native CLI can discover bundled MCP sibling without npm bin on PATH', () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'c2c-siblings-'));
  const cli=path.join(dir,'c2c');
  fs.writeFileSync(cli,'#!/bin/sh\ncommand -v c2c-mcp-server\n',{mode:0o755});
  fs.writeFileSync(path.join(dir,'c2c-mcp-server'),'#!/bin/sh\nexit 0\n',{mode:0o755});
  const wrapper=path.resolve(__dirname,'../bin/c2c-js-wrapper.js');
  const result=spawnSync(process.execPath,[wrapper],{encoding:'utf8', env:{PATH:'/usr/bin:/bin',C2C_BIN:cli}});
  assert.equal(result.status,0,result.stderr);
  assert.equal(result.stdout.trim(),path.join(dir,'c2c-mcp-server'));
});
