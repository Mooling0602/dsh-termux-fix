#!/usr/bin/env node
// dsh-termux-fix: make dsh survive Android's SELinux link() ban.
//
// Android blocks hard links entirely (EACCES), except that link(2) to an
// already-existing target reports EEXIST first. dsh uses link() in three
// places, all as an atomic exclusive-create publish:
//   1. dsh-session-persistence-jsonl  publishCurrentExclusive (migration publish)
//   2. dsh-session-persistence-jsonl  materializePosix        (session create)
//   3. dsh-attachment-local           publishImmutableAlias / publishStagedObject
// Fallbacks:
//   1+2: renameat2(RENAME_NOREPLACE) via our local system.node binding —
//        atomic exclusive create, EEXIST on collision (same contract).
//   3:   copyFile — targets are content-addressed, so a racing duplicate
//        write is byte-identical and the following digest check still guards.
// Each patch is independently idempotent (skipped when its marker is present).
//
// The attachment store has a second Android problem that has nothing to do with
// link(): before publishing, it fsyncs every ancestor directory from the
// attachment home up to the filesystem root. Android denies opening /data/data
// (mode 0711, owned by the system), so that walk throws EACCES and every
// attachment write — file or image — fails before link() is ever reached. The
// walk stops at the first ancestor the process may not open; everything below
// it is already synced, and the unreadable entries belong to the package
// manager rather than to this process.
import { readFileSync, writeFileSync } from 'node:fs';

const files = process.argv.slice(2);
if (!files.length) {
    console.error('usage: patch-session-persistence.mjs <file...>');
    process.exit(1);
}

const renameNoReplaceCall = (from, to) => `_dshTermuxLoadSystem().renameNoReplace(${from}, ${to}, (errno) => {
						if (errno === 0) resolve();
						else reject(Object.assign(new Error(\`renameat2 RENAME_NOREPLACE failed: \${errno}\`), { code: errno === 17 ? "EEXIST" : \`ERRNO_\${errno}\` }));
					})`;

const ESM_HELPER = {
    id: 'session-persistence esm helper',
    anchor: 'import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock";',
    applied: (src) => src.includes('function _dshTermuxLoadSystem'),
    replacement: `import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock";
/* dsh-termux-fix: Android SELinux blocks link(); publish falls back to renameat2(RENAME_NOREPLACE). */
import { createRequire as _dshTermuxCreateRequire } from "node:module";
const _dshTermuxRequire = _dshTermuxCreateRequire(import.meta.url);
let _dshTermuxSystemBinding;
function _dshTermuxLoadSystem() {
	_dshTermuxSystemBinding ??= _dshTermuxRequire("@deepseek-ai/node-addon-system-android-arm64/bin/system.node");
	return _dshTermuxSystemBinding;
}`,
};

const CJS_HELPER = {
    id: 'session-persistence cjs helper',
    anchor: 'let node_util = require("node:util");',
    applied: (src) => src.includes('function _dshTermuxLoadSystem'),
    replacement: `let node_util = require("node:util");
/* dsh-termux-fix: Android SELinux blocks link(); publish falls back to renameat2(RENAME_NOREPLACE). */
let _dshTermuxSystemBinding = null;
function _dshTermuxLoadSystem() {
	if (!_dshTermuxSystemBinding) _dshTermuxSystemBinding = require("@deepseek-ai/node-addon-system-android-arm64/bin/system.node");
	return _dshTermuxSystemBinding;
}`,
};

// publishCurrentExclusive: identical text in index.js and worker.cjs.
const PUBLISH_CURRENT = {
    id: 'publishCurrentExclusive fallback',
    applied: (src) => src.includes('renameNoReplace(staged, currentPath'),
    anchor: `	try {
		await internals.fs.link(staged, currentPath);
	} catch (error) {
		/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
		if (isEEXIST(error)) return false;
		/* v8 ignore next -- the filesystem error is already complete. */
		throw error;
	}`,
    replacement: `	try {
		await internals.fs.link(staged, currentPath);
	} catch (error) {
		/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
		if (isEEXIST(error)) return false;
		/* dsh-termux-fix: Android SELinux denies link() outright (EACCES/EPERM).
		   Emulate the exclusive-create publish with renameat2(RENAME_NOREPLACE):
		   atomic exclusive create that reports EEXIST on collision — the same
		   contract as link-when-absent. */
		if (error?.code === "EACCES" || error?.code === "EPERM") {
			try {
				await new Promise((resolve, reject) => {
					${renameNoReplaceCall('staged', 'currentPath')}
				});
			} catch (renameError) {
				if (isEEXIST(renameError)) return false;
				throw renameError;
			}
			await syncDirectory(DIRNAME_EXPR(currentPath), internals);
			return true;
		}
		/* v8 ignore next -- the filesystem error is already complete. */
		throw error;
	}`,
};

// materializePosix: session creation (header line + first batch).
const MATERIALIZE = {
    id: 'materializePosix fallback',
    applied: (src) => src.includes('renameNoReplace(tmp, finalPath'),
    anchor: `		try {
			await link(tmp, finalPath);
			linked = true;
		} finally {`,
    replacement: `		try {
			await link(tmp, finalPath);
			linked = true;
		} catch (error) {
			/* dsh-termux-fix: Android SELinux denies link() outright (EACCES/EPERM).
			   Fall back to renameat2(RENAME_NOREPLACE) — atomic exclusive create,
			   same no-replace contract as link-when-absent. */
			if (error?.code === "EACCES" || error?.code === "EPERM") {
				await new Promise((resolve, reject) => {
					${renameNoReplaceCall('tmp', 'finalPath')}
				});
				linked = true;
			} else {
				throw error;
			}
		} finally {`,
};

const ATT_IMPORT = {
    id: 'attachment-local copyFile import',
    applied: (src) => src.includes('{ chmod, copyFile, link,'),
    anchor: 'import { chmod, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";',
    replacement: 'import { chmod, copyFile, link, mkdir, open, readFile, rename, rm, unlink, writeFile } from "node:fs/promises";',
};

const ATT_ALIAS = {
    id: 'attachment alias fallback',
    applied: (src) => src.includes('dsh-termux-fix: attachment alias'),
    anchor: `		try {
			await link(source, target);
		} catch (error) {
			/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
			if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
			if (await digestFile(target) !== sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
		}`,
    replacement: `		try {
			await link(source, target);
		} catch (error) {
			/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
			if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) {
				/* dsh-termux-fix: attachment alias — Android SELinux denies link(); copy instead.
				   The target is content-addressed, so a racing duplicate write is byte-identical. */
				if (!(error instanceof Error && "code" in error && (error.code === "EACCES" || error.code === "EPERM"))) throw error;
				await copyFile(source, target);
			}
			if (await digestFile(target) !== sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
		}`,
};

const ATT_STAGED = {
    id: 'attachment publish fallback',
    applied: (src) => src.includes('dsh-termux-fix: attachment publish'),
    anchor: `		try {
			await link(staged.path, target);
		} catch (error) {
			/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
			if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
			if (await digestFile(target) !== staged.sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
		}`,
    replacement: `		try {
			await link(staged.path, target);
		} catch (error) {
			/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */
			if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) {
				/* dsh-termux-fix: attachment publish — Android SELinux denies link(); copy instead.
				   The target is content-addressed, so a racing duplicate write is byte-identical. */
				if (!(error instanceof Error && "code" in error && (error.code === "EACCES" || error.code === "EPERM"))) throw error;
				await copyFile(staged.path, target);
			}
			if (await digestFile(target) !== staged.sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");
		}`,
};

const ATT_DURABLE = {
    id: 'attachment durable walk fallback',
    applied: (src) => src.includes('dsh-termux-fix: durable sync'),
    anchor: `	let level = target;
	while (level !== stop) {
		const parent = dirname(level);
		await syncDirectory(parent);
		/* v8 ignore next -- filesystem-root guard: callers pass a boundary that is an ancestor of path, so the walk reaches it first. */
		if (parent === level) return;
		level = parent;
	}`,
    replacement: `	let level = target;
	while (level !== stop) {
		const parent = dirname(level);
		try {
			await syncDirectory(parent);
		} catch (error) {
			/* dsh-termux-fix: durable sync stops at an unreadable ancestor.
			   Android denies opening /data/data (mode 0711, system-owned), so
			   fsyncing every ancestor up to / is impossible on Termux. Everything
			   from the attachment home down is already synced; the entries above
			   the app's private root belong to the package manager. */
			if (error?.code === "EACCES" || error?.code === "EPERM") return;
			throw error;
		}
		/* v8 ignore next -- filesystem-root guard: callers pass a boundary that is an ancestor of path, so the walk reaches it first. */
		if (parent === level) return;
		level = parent;
	}`,
};

const SPECS = [
    {
        match: /dsh-session-persistence-jsonl\/lib\/index\.js$/,
        patches: [ESM_HELPER, { ...PUBLISH_CURRENT, dirnameExpr: 'dirname' }, MATERIALIZE],
    },
    {
        match: /dsh-session-persistence-jsonl\/lib\/worker\.cjs$/,
        patches: [CJS_HELPER, { ...PUBLISH_CURRENT, dirnameExpr: '(0, node_path.dirname)' }],
    },
    {
        match: /dsh-attachment-local\/lib\/index\.js$/,
        patches: [ATT_IMPORT, ATT_ALIAS, ATT_STAGED, ATT_DURABLE],
    },
];

const count = (haystack, needle) => haystack.split(needle).length - 1;

for (const file of files) {
    const spec = SPECS.find((s) => s.match.test(file));
    if (!spec) {
        console.error(`unsupported file: ${file}`);
        process.exit(1);
    }
    let src = readFileSync(file, 'utf8');
    let changed = false;
    for (const patch of spec.patches) {
        if (patch.applied(src)) {
            console.log(`    ${file.split('/').pop()}: ${patch.id} — already applied, skip`);
            continue;
        }
        const anchor = 'dirnameExpr' in patch ? patch.anchor.replaceAll('DIRNAME_EXPR', 'PLACEHOLDER') && patch.anchor : patch.anchor;
        const replacement = 'dirnameExpr' in patch ? patch.replacement.replaceAll('DIRNAME_EXPR', patch.dirnameExpr) : patch.replacement;
        if (count(src, anchor) !== 1) {
            console.error(`    ${file.split('/').pop()}: ${patch.id} — anchor found ${count(src, anchor)} times (expected 1), upstream layout changed`);
            process.exit(1);
        }
        src = src.replace(anchor, replacement);
        changed = true;
        console.log(`    ${file.split('/').pop()}: ${patch.id} — patched`);
    }
    if (changed) writeFileSync(file, src);
}
