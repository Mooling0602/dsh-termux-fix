#!/usr/bin/env node
// dsh-termux-fix: repair the two "missing platform package" gaps that have
// nothing to do with install flags.
//
// Both failures are the same shape: a dependency resolves a per-platform
// binary through `require.resolve()`, the npm registry publishes no Android
// entry for that platform, so the resolution throws lazily at first use.
//
//   A. dsh-tool-fs-search -> @vscode/ripgrep -> @vscode/ripgrep-<platform>-<arch>/bin/rg
//      The registry has twelve ripgrep platform packages and none is android.
//      Fix: create @vscode/ripgrep-android-arm64/bin/rg as a shim onto the
//      system ripgrep Termux already ships. The shim is a symlink, so the
//      binary stays the same one `rg` on the command line runs.
//
//   B. dsh-fs-local -> link(tempPath, absolutePath) as an exclusive-create
//      publish. Android SELinux denies link(2) outright (EACCES/EPERM), so
//      every `write` tool call fails while the file is absent. Fix: fall back
//      to renameat2(RENAME_NOREPLACE) — atomic, and reports EEXIST on
//      collision, which is exactly the contract link-when-absent provided.
//
// Each fix is independently idempotent and verifies itself after writing.
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const action = process.argv[2];
const dmod = process.argv[3];
if (!action || !dmod) {
    console.error('usage: patch-platform-gaps.mjs <ripgrep|fs-local|all> <dsh node_modules dir>');
    process.exit(1);
}

const RG_PKG = join(dmod, '@vscode/ripgrep-android-arm64');
const FS_LOCAL = join(dmod, '@deepseek-ai/dsh-fs-local/lib/index.js');

// --- A. ripgrep platform package ------------------------------------------
function patchRipgrep() {
    const shim = join(RG_PKG, 'bin/rg');
    mkdirSync(join(RG_PKG, 'bin'), { recursive: true });

    // A symlink keeps the shim honest: whatever the user updates with `pkg
    // upgrade ripgrep` is what dsh runs. Termux puts rg in $PREFIX/bin.
    const candidates = [
        process.env.PREFIX ? join(process.env.PREFIX, 'bin/rg') : undefined,
        '/data/data/com.termux/files/usr/bin/rg',
    ].filter(Boolean);
    const systemRg = candidates.find((p) => existsSync(p));
    if (!systemRg) {
        console.error('    ripgrep: no system rg found (looked at: ' + candidates.join(', ') + ')');
        console.error('    ripgrep: install it with `pkg install ripgrep`');
        return false;
    }

    if (!existsSync(join(RG_PKG, 'package.json'))) {
        writeFileSync(
            join(RG_PKG, 'package.json'),
            JSON.stringify(
                {
                    name: '@vscode/ripgrep-android-arm64',
                    version: '1.18.0',
                    private: true,
                    description:
                        'dsh-termux-fix shim: upstream publishes no Android ripgrep package, so this points at the system binary',
                    os: ['android'],
                    cpu: ['arm64'],
                },
                null,
                2,
            ) + '\n',
        );
    }

    rmSync(shim, { force: true });
    symlinkSync(systemRg, shim);
    console.log(`    ripgrep: ${shim} -> ${systemRg}`);

    // Verify the way dsh resolves it: through @vscode/ripgrep's own code.
    const entry = join(dmod, '@vscode/ripgrep/lib/index.js');
    const probe = spawnSync(
        process.execPath,
        [
            '--input-type=module',
            '-e',
            `import(${JSON.stringify(pathToFileURL(entry).href)})` +
                `.then((m) => console.log(m.rgPath)).catch((e) => { console.error(e.message); process.exit(1); });`,
        ],
        { encoding: 'utf8' },
    );
    if (probe.status !== 0) {
        console.error('    ripgrep: @vscode/ripgrep still cannot resolve — ' + probe.stderr.trim());
        return false;
    }
    const rgPath = probe.stdout.trim();
    const run = spawnSync(rgPath, ['--no-config', '--version'], { encoding: 'utf8' });
    if (run.status !== 0) {
        console.error(`    ripgrep: ${rgPath} will not run — ${run.stderr.trim()}`);
        return false;
    }
    console.log(`    ripgrep: resolves and runs (${run.stdout.split('\n')[0]})`);
    return true;
}

// --- B. dsh-fs-local link() fallback --------------------------------------
const HELPER_MARK = 'dsh-termux-fix: fs-local link helper';

const IMPORT_ANCHOR =
    'import { chmod, link, lstat, mkdir, open, readFile, readdir, rename, rm, stat } from "node:fs/promises";';

const HELPER = `${IMPORT_ANCHOR}
/* dsh-termux-fix: fs-local link helper — Android SELinux denies link(2) outright. */
import { createRequire as _dshTermuxCreateRequire } from "node:module";
const _dshTermuxRequire = _dshTermuxCreateRequire(import.meta.url);
let _dshTermuxSystemBinding;
function _dshTermuxLoadSystem() {
	_dshTermuxSystemBinding ??= _dshTermuxRequire("@deepseek-ai/node-addon-system-android-arm64/bin/system.node");
	return _dshTermuxSystemBinding;
}
const _dshTermuxRenameNoReplace = (from, to) => new Promise((resolve, reject) => {
	_dshTermuxLoadSystem().renameNoReplace(from, to, (errno) => {
		if (errno === 0) resolve();
		else reject(Object.assign(new Error(\`renameat2 RENAME_NOREPLACE failed: \${errno}\`), { code: errno === 17 ? "EEXIST" : \`ERRNO_\${errno}\` }));
	});
});`;

const PUBLISH_ANCHOR = `		if (createIfAbsent !== void 0) try {
			await linkFile(tempPath, absolutePath);
		} catch (error) {
			await throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
		}`;

const PUBLISH_REPLACEMENT = `		if (createIfAbsent !== void 0) try {
			await linkFile(tempPath, absolutePath);
		} catch (error) {
			/* dsh-termux-fix: Android SELinux denies link() outright (EACCES/EPERM), and
			   this branch is the exclusive-create half of every write to a missing file —
			   without a fallback the write tool cannot create anything. renameat2 with
			   RENAME_NOREPLACE is atomic and reports EEXIST on collision, which is the
			   same contract link-when-absent gave the caller. */
			const _dshTermuxDenied = error instanceof Error && "code" in error && (error.code === "EACCES" || error.code === "EPERM");
			if (_dshTermuxDenied) {
				try {
					await _dshTermuxRenameNoReplace(tempPath, absolutePath);
				} catch (renameError) {
					await throwGuardedCreateFailure(renameError, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
				}
			} else await throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
		}`;

const count = (haystack, needle) => haystack.split(needle).length - 1;

function patchFsLocal() {
    if (!existsSync(FS_LOCAL)) {
        console.error(`    fs-local: missing ${FS_LOCAL}`);
        return false;
    }
    const original = readFileSync(FS_LOCAL, 'utf8');
    let src = original;
    let changed = false;

    // Two independent rewrites, applied in one pass. This used to recurse back
    // into itself after each write, which turned a marker mismatch (the comment
    // says "link() helper", the marker said "link helper") into an unbounded
    // loop that kept re-inserting the helper. Sequential and idempotent now:
    // a marker that does not match its own comment is a loud failure, not a spin.
    if (!src.includes(HELPER_MARK)) {
        if (count(src, IMPORT_ANCHOR) !== 1) {
            console.error('    fs-local: import anchor not found exactly once (upstream layout changed)');
            return false;
        }
        src = src.replace(IMPORT_ANCHOR, HELPER);
        changed = true;
        console.log('    fs-local: helper inserted');
    }

    if (!src.includes('_dshTermuxRenameNoReplace(tempPath, absolutePath)')) {
        if (count(src, PUBLISH_ANCHOR) !== 1) {
            console.error('    fs-local: publish anchor not found exactly once (upstream layout changed)');
            return false;
        }
        src = src.replace(PUBLISH_ANCHOR, PUBLISH_REPLACEMENT);
        changed = true;
        console.log('    fs-local: exclusive-create publish falls back to renameat2(RENAME_NOREPLACE)');
    }

    // Both markers must now be present, whether or not this run wrote anything.
    // A file that reports "already patched" while missing a half is the exact
    // failure mode --check exists to catch.
    for (const [marker, label] of [
        [HELPER_MARK, 'helper'],
        ['_dshTermuxRenameNoReplace(tempPath, absolutePath)', 'publish fallback'],
    ]) {
        if (!src.includes(marker)) {
            console.error(`    fs-local: ${label} missing after patching — refusing to write`);
            return false;
        }
    }

    if (changed) writeFileSync(FS_LOCAL, src);

    // Verify: the result must parse, and the file must have grown by the two
    // insertions rather than by a runaway loop.
    const check = spawnSync(process.execPath, ['--check', FS_LOCAL], { encoding: 'utf8' });
    if (check.status !== 0) {
        console.error('    fs-local: patched file does not parse — ' + check.stderr.trim());
        return false;
    }
    if (changed) console.log(`    fs-local: ${original.length} -> ${src.length} bytes, parses cleanly`);
    else console.log('    fs-local: already patched, parses cleanly');
    return true;
}

const steps = { ripgrep: patchRipgrep, 'fs-local': patchFsLocal };
const wanted = action === 'all' ? Object.keys(steps) : [action];
let failed = false;
for (const name of wanted) {
    if (!steps[name]) {
        console.error(`unknown target: ${name}`);
        process.exit(1);
    }
    console.log(`  ${name}`);
    if (!steps[name]()) failed = true;
}
process.exit(failed ? 1 : 0);
