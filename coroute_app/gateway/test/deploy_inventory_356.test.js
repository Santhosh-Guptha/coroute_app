'use strict';
/**
 * Round 6 clean-up (a): tracked deploy material and docs hold no real OCIDs, public IP addresses, personal e-mail
 * addresses or key material. Real values live in the git-ignored deploy/inventory.local.env (template:
 * deploy/inventory.example.env); scripts read them through deploy/_inventory.py / _inventory.sh and stop with a
 * clear message when a value is missing.
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const GW = path.join(__dirname, '..');
const REPO = path.join(GW, '..');
const DEPLOY = path.join(GW, 'deploy');

function walk(dir, keep, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.git', '__pycache__', 'licenses', 'build', '.dart_tool'].includes(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, keep, out);
    else if (keep(p)) out.push(p);
  }
  return out;
}
const isText = (p) => /\.(md|sh|py|js|env|service|timer|sql|yml|yaml|txt|json)$|Caddyfile|\.example\.env$/.test(p) && !/inventory\.local\.env$/.test(p);
const files = () => [
  ...walk(DEPLOY, isText),
  ...walk(path.join(REPO, 'docs'), (p) => p.endsWith('.md')),
  ...fs.readdirSync(REPO).filter((f) => f.endsWith('.md')).map((f) => path.join(REPO, f)),
];

const reserved = (a, b, ip) => a === 10 || a === 127 || a === 0 || a === 169 || a >= 224 || (a === 192 && (b === 168 || b === 0))
  || (a === 172 && b >= 16 && b <= 31) || (a === 198 && (b === 51 || b === 18 || b === 19)) || (a === 203 && b === 0) || (a === 100 && b >= 64 && b <= 127)
  || ['1.1.1.1', '8.8.8.8', '8.8.4.4', '1.0.0.1', '1.2.3.4', '9.9.9.9'].includes(ip);

test('no real OCID, public IPv4 address, personal e-mail address or private key in tracked deploy files and docs', () => {
  const bad = [];
  for (const f of files()) {
    const rel = path.relative(REPO, f);
    fs.readFileSync(f, 'utf8').split('\n').forEach((line, i) => {
      const at = `${rel}:${i + 1}`;
      if (/ocid1\.[a-z0-9]+\.oc1\.[a-z0-9-]*\.[a-z0-9]{30,}/.test(line)) bad.push(`OCID ${at}`);
      for (const m of line.matchAll(/(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])/g)) {
        const [a, b, c, d] = m.slice(1).map(Number);
        if ([a, b, c, d].some((x) => x > 255)) continue;
        if (/version|v\d|\bnode\b|flutter|gradle|sdk|build|release|chrome|android|ios |kotlin|dart|package|@/i.test(line) && !/ssh|ip\b|addr|host|vm\d|node \d/i.test(line)) continue; // version numbers
        if (!reserved(a, b, m[0])) bad.push(`public IPv4 ${m[0]} ${at}`);
      }
      if (/[A-Za-z0-9._%+-]+@(gmail|yahoo|outlook|hotmail|icloud|proton(mail)?)\.[a-z.]+/i.test(line) && !/example|your|<|someone|rider\d*@|name@/i.test(line)) bad.push(`personal e-mail ${at}`);
      if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(line)) bad.push(`private key ${at}`);
      if (/ssh-(rsa|ed25519) AAAA[A-Za-z0-9+/]{60,}/.test(line)) bad.push(`ssh public key ${at}`);
      if (/echo\s+"?[a-z_][a-z0-9_-]*:[^"$\s]{6,}"?\s*\|\s*chpasswd/.test(line)) bad.push(`password ${at}`);
    });
  }
  assert.deepEqual(bad, [], 'move these to deploy/inventory.local.env (git-ignored) or the environment');
});

test('the inventory template holds placeholders for every value the scripts need', () => {
  const tpl = fs.readFileSync(path.join(DEPLOY, 'inventory.example.env'), 'utf8');
  for (const k of ['VM1_PRIVATE_IP', 'VM2_PRIVATE_IP', 'VM1_PUBLIC_IP', 'VM2_PUBLIC_IP', 'OCI_TENANCY_OCID', 'OCI_COMPARTMENT_OCID', 'OCI_REGION',
    'OCI_AVAILABILITY_DOMAIN', 'OCI_VCN_OCID', 'OCI_SUBNET_OCID', 'OCI_ADB_OCID', 'OCI_ARM_IMAGE_OCID', 'OCI_X86_IMAGE_OCID', 'VM_SSH_PUBLIC_KEY_FILE',
    'VM_SSH_PRIVATE_KEY_FILE', 'ADB_ACL_EXTRA_IPS', 'VM_ADMIN_USERS', 'BOOTSTRAP_ADMIN_EMAILS', 'GOOGLE_CLIENT_IDS', 'ORACLE_SODA_URL']) {
    assert.match(tpl, new RegExp(`^${k}=`, 'm'), k);
  }
  for (const line of tpl.split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=("?)(.*?)\2\s*(#.*)?$/);
    if (!m || !/OCID|_IP$|EMAILS|KEY_FILE|SODA_URL|CLIENT_IDS|ADMIN_USERS/.test(m[1])) continue;
    assert.ok(m[3] === '' || /^<.*>$/.test(m[3]), `${m[1]} must be a <placeholder> in the template, got ${m[3]}`);
  }
});

test('scripts read the inventory and stop with a clear message when a value is missing', (t) => {
  const py = spawnSync('python3', ['--version']);
  for (const f of ['auto_provision_ampere.py', 'smart_free_provisioner.py', 'update_adb_acl.py']) {
    const src = fs.readFileSync(path.join(DEPLOY, f), 'utf8');
    assert.match(src, /from _inventory import/, f);
    assert.doesNotMatch(src, /ocid1\.[a-z]+\.oc1/, f);
  }
  for (const f of ['setup_new_vm.sh', 'setup_vm2.sh', 'harden_security.sh', 'audit_security.sh']) {
    assert.match(fs.readFileSync(path.join(DEPLOY, f), 'utf8'), /_inventory\.sh"\nneed [A-Z_ ]+/, f);
  }
  const bashBin = process.platform === 'win32' && fs.existsSync('C:\\Program Files\\Git\\bin\\bash.exe')
    ? 'C:\\Program Files\\Git\\bin\\bash.exe'
    : 'bash';
  const shScript = path.join(DEPLOY, '_inventory.sh').replace(/\\/g, '/');
  const env = { PATH: process.env.PATH, HOME: process.env.HOME || '/tmp', COROUTE_INVENTORY: path.join(DEPLOY, 'does-not-exist.env').replace(/\\/g, '/') };
  const sh = spawnSync(bashBin, ['-c', `. "${shScript}"; need VM2_PRIVATE_IP; echo reached`], { env, encoding: 'utf8' });
  assert.equal(sh.status, 2);
  assert.match(sh.stderr, /VM2_PRIVATE_IP is not set/);
  assert.doesNotMatch(sh.stdout, /reached/);
  const tplRun = spawnSync(bashBin, ['-c', `. "${shScript}"; need VM2_PRIVATE_IP`], { env: { ...env, COROUTE_INVENTORY: path.join(DEPLOY, 'inventory.example.env').replace(/\\/g, '/') }, encoding: 'utf8' });
  assert.equal(tplRun.status, 2, 'a <placeholder> of the template counts as missing');
  const ok = spawnSync(bashBin, ['-c', `. "${shScript}"; need VM2_PRIVATE_IP; echo "got $VM2_PRIVATE_IP"`], { env: { ...env, VM2_PRIVATE_IP: '10.9.8.7' }, encoding: 'utf8' });
  assert.equal(ok.status, 0); assert.match(ok.stdout, /got 10\.9\.8\.7/);
  if (py.status !== 0) return t.diagnostic('python3 not installed: python inventory check skipped');
  const run = spawnSync('python3', [path.join(DEPLOY, 'update_adb_acl.py')], { env, encoding: 'utf8' });
  assert.equal(run.status, 2);
  assert.match(run.stderr, /OCI_ADB_OCID is not set/);
  assert.match(run.stderr, /inventory\.example\.env/);
  return undefined;
});
