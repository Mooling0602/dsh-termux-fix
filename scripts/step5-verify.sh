#!/usr/bin/env bash
# Step 5 — verify every binding actually loads and works.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DMOD=$(resolve_dsh_modules)
info "verifying"

node --input-type=module -e "
import { createRequire } from 'node:module';
import { openSync, mkdtempSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const D = process.argv[1];
const require = createRequire(D + '/@deepseek-ai/node-addon-system/lib/x.js');
const fail = (m) => { console.error('  fail ' + m); process.exit(1); };

// 1. koffi
try { require(D + '/koffi'); console.log('  ok koffi'); }
catch (e) { fail('koffi: ' + e.message); }

// 2. require-builtin
try {
    const rb = require(D + '/node-addon-require-builtin');
    if (rb.getBindingInfo().product !== 'require-builtin') fail('require-builtin: product mismatch');
    rb.requireBuiltin('internal/modules/cjs/loader');
    console.log('  ok require-builtin');
} catch (e) { fail('require-builtin: ' + e.message); }

// 3. flock
try {
    const { tryLockExclusive } = await import(D + '/@deepseek-ai/node-addon-system/lib/flock.js');
    const dir = mkdtempSync(join(tmpdir(), 'dshfix-'));
    const fd = openSync(join(dir, 'lock'), 'w');
    await tryLockExclusive(fd);
    console.log('  ok flock');
} catch (e) { fail('flock: ' + e.message); }

// 4. renameNoReplace
try {
    const sys = require(D + '/@deepseek-ai/node-addon-system-android-arm64/bin/system.node');
    if (typeof sys.renameNoReplace !== 'function') fail('system: renameNoReplace missing');
    const dir = mkdtempSync(join(tmpdir(), 'dshfix-'));
    const a = join(dir, 'a'), b = join(dir, 'b');
    writeFileSync(a, 'x');
    const errno1 = await new Promise((res) => sys.renameNoReplace(a, b, res));
    if (errno1 !== 0) fail('renameNoReplace: expected 0, got ' + errno1);
    // second call must collide with EEXIST (17) — the link-when-absent contract
    writeFileSync(a, 'y');
    const errno2 = await new Promise((res) => sys.renameNoReplace(a, b, res));
    if (errno2 !== 17) fail('renameNoReplace: expected EEXIST(17), got ' + errno2);
    console.log('  ok renameNoReplace (incl. EEXIST contract)');
} catch (e) { fail('system: ' + e.message); }
" "$DMOD" || die "verification failed"

ok "all bindings verified"
