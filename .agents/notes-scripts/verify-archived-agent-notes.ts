/**
 * Verify frozen archived Agent Notes: exact head layout, manifest.json seals,
 * append-only extension vs a git baseline (skipped gracefully without git).
 * Usage:
 *   npx tsx <skill-dir>/scripts/verify-archived-agent-notes.ts          # verify only
 *   npx tsx <skill-dir>/scripts/verify-archived-agent-notes.ts --write  # verify, then seal unsealed files
 * Env: AGENT_NOTE_ARCHIVE_BASE_REF (default HEAD) — git ref the manifest is compared against.
 */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { agentNoteRoot } from "./agent-note-tree.ts";

const isWrite = process.argv.includes("--write");
const errors: string[] = [];
const warnings: string[] = [];
const fail = (msg: string) => { errors.push(msg); };

// --- collect archived files (skip accidental .zh.md)
const archivedDir = join(agentNoteRoot, "archived");
const files: string[] = [];
function scan(dir: string) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) scan(full);
    else if (entry.isFile() && entry.name.endsWith(".md") && !entry.name.endsWith(".zh.md")) {
      const rel = relative(archivedDir, full).split("\\").join("/");
      if (rel === "AGENTS.md" || rel === "manifest.json") continue;
      files.push(rel);
    }
  }
}
if (existsSync(archivedDir)) scan(archivedDir);

// --- head layout: L1 title / L2 blank / L3 Status / L4 Archived / L5 blank
const TITLE_RE = /^# Agent Note[:：] ?\S/;
const ARCHIVED_RE = /^Archived: \d{4}-\d{2}-\d{2}$/;
for (const rel of files) {
  const lines = readFileSync(join(archivedDir, rel), "utf8").replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n").split("\n");
  if (!TITLE_RE.test(lines[0] ?? "")) fail(`${rel} — line 1 must be \`# Agent Note: <title>\``);
  if (lines[1] !== "") fail(`${rel} — line 2 must be blank`);
  if (lines[2] !== "Status: implemented") fail(`${rel} — line 3 must be \`Status: implemented\``);
  if (!ARCHIVED_RE.test(lines[3] ?? "")) fail(`${rel} — line 4 must be \`Archived: YYYY-MM-DD\` immediately below Status`);
  if (lines[4] !== "") fail(`${rel} — line 5 must be blank after Archived`);
}

// --- manifest seals
const manifestPath = join(archivedDir, "manifest.json");
interface Manifest { version: 1; files: Record<string, string>; }
let manifest: Manifest = { version: 1, files: {} };
if (existsSync(manifestPath)) {
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch {
    fail("archived/manifest.json exists but is not valid JSON");
  }
} else if (files.length > 0 && !isWrite) {
  fail("archived/manifest.json missing — run with --write to seal existing archived notes");
}

const sealOf = (relFromRoot: string) =>
  `sha256:${createHash("sha256").update(readFileSync(join(agentNoteRoot, relFromRoot))).digest("hex")}`;

for (const rel of files) {
  const key = `archived/${rel}`;
  const entry = manifest.files[key];
  if (!entry) {
    if (isWrite) {
      manifest.files[key] = sealOf(key);
    } else {
      fail(`${key} — missing seal in manifest.json (run with --write)`);
    }
  } else if (entry !== sealOf(key)) {
    fail(`${key} — seal mismatch: archived note was modified after sealing (frozen notes must never change)`);
  }
}
for (const key of Object.keys(manifest.files)) {
  if (!existsSync(join(agentNoteRoot, key))) fail(`${key} — sealed entry has no file on disk`);
}

// --- append-only vs git baseline (skipped without git)
const repoRoot = (() => {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: agentNoteRoot, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
  } catch {
    return null;
  }
})();
if (repoRoot) {
  /* 基线的三种「查不到」必须分开对待，不能一律当成「没有可比的东西」：
     ① `AGENT_NOTE_ARCHIVE_BASE_REF` 指向一个**解析不出来的 ref**、
     ② 全零 sha（CI 新分支 push 的 `github.event.before` 就是这个形状）、
     ③ `git` 读失败（权限、损坏、超时）——
     这三种都是**门禁没查**，不是**没有可查的**。以前它们全部静默通过，
     于是这一步在 CI 上恒绿：实测 `AGENT_NOTE_ARCHIVE_BASE_REF=refs/heads/nope`
     与 `AGENT_NOTE_ARCHIVE_BASE_REF=0000…0` 都打印
     `ok: 1 archived note(s) verified, 1 seal(s) in manifest` 并 exit 0。

     只有「基线提交里确实没有 archived/manifest.json」才是真正无可比 ——
     那种情况用 `ls-tree` 判定（列出树条目），而不是靠 `git show` 抛错。 */
  const explicitBase = process.env.AGENT_NOTE_ARCHIVE_BASE_REF;
  const baseRefRaw = explicitBase === undefined || explicitBase.trim() === "" ? "HEAD" : explicitBase.trim();
  const gitOut = (args: string[]): { ok: boolean; out: string; err: string } => {
    try {
      const out = execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
      return { ok: true, out, err: "" };
    } catch (error) {
      const e = error as { stdout?: string; stderr?: string; message?: string };
      return { ok: false, out: e.stdout ?? "", err: (e.stderr ?? "").trim() || (e.message ?? "") };
    }
  };

  const zerosRef = /^0+$/.test(baseRefRaw);
  if (zerosRef) {
    fail(
      `AGENT_NOTE_ARCHIVE_BASE_REF 是全零 sha（CI 新分支 push 的 event.before 就是这个值）：` +
        `这说明本次没有可比基线，append-only 校验没有执行 —— 请改用 merge-base 或 PR base，不要让它静默通过`
    );
  }

  const resolved = gitOut(["rev-parse", "--verify", "--end-of-options", `${baseRefRaw}^{commit}`]);
  const baseOid = resolved.out.trim();

  if (zerosRef) {
    /* 已在上面报过「全零 sha 没有可比基线」，不再叠加一条同因的解析失败。 */
  } else if (!resolved.ok) {
    /* HEAD 未出生（全新仓库、还没有第一个提交）是唯一可以放行的情形：
       此时既没有历史也没有封印可比，而显式给出的 ref 解析不出来就是错。 */
    const unborn = baseRefRaw === "HEAD" && gitOut(["rev-parse", "--verify", "--quiet", "HEAD"]).out.trim() === "";
    if (unborn) {
      warnings.push("仓库还没有第一个提交 — append-only 校验无可比基线（封印哈希仍已按磁盘核对）");
    } else {
      fail(`AGENT_NOTE_ARCHIVE_BASE_REF=${baseRefRaw} 无法解析为提交，append-only 校验没有执行：${resolved.err.trim()}`);
    }
  } else if (baseOid !== "") {
    /* 清单在**提交里**的路径，必须与 git 的视角一致。
       不能写 `relative(repoRoot, manifestPath)`：`repoRoot` 来自 git
       （`C:/Users/iuuuuuuuu/...`），`manifestPath` 来自 Node 的路径解析
       （Windows 8.3 短名 `C:\Users\IUUUUU~1\...`）。两个字符串指向同一个目录，
       但 `relative()` 只比字面量，于是算出 `../../../../IUUUUU~1/...`，
       `ls-tree` 直接报 "is outside repository" —— 门禁红在一个**与内容无关**的原因上。
       2026-10-22 在真仓库里实测到这条（`git rev-parse --show-toplevel` 与
       `process.cwd()` 在临时目录/短用户名下确实不同形）。

       正确做法：git 只回答「仓库根到当前目录」这一段（`--show-prefix`），
       剩下「当前目录到清单」这一段用 Node 自己的 cwd 算 —— 两边各自只比
       自己体系的路径，不跨体系比较。 */
    const prefixRes = gitOut(["rev-parse", "--show-prefix"]);
    const prefix = prefixRes.ok ? prefixRes.out.trim() : "";
    const fromCwd = relative(process.cwd(), manifestPath).split("\\").join("/");
    const manifestRel = `${prefix}${fromCwd}`;
    /* 用 ls-tree 判「基线里有没有这份清单」：它把「路径不存在」与「读失败」
       分开表达，而 `git show` 对两者都抛错。 */
    const listed = gitOut(["--literal-pathspecs", "ls-tree", "--full-tree", "-z", baseOid, "--", manifestRel]);
    if (!listed.ok) {
      fail(`读取基线 ${baseRefRaw} 的树失败，append-only 校验没有执行：${listed.err.trim()}`);
    } else if (listed.out.trim() !== "") {
      const shown = gitOut(["show", `${baseOid}:${manifestRel}`]);
      if (!shown.ok) {
        fail(`读取基线 ${baseRefRaw} 的 archived/manifest.json 失败：${shown.err.trim()}`);
      } else {
        try {
          const baseline = JSON.parse(shown.out) as Manifest;
          for (const [key, seal] of Object.entries(baseline.files ?? {})) {
            if (manifest.files[key] !== seal) {
              fail(`${key} — seal added/changed/removed relative to ${baseRefRaw}; archived seals are append-only`);
            }
          }
        } catch {
          fail(`archived/manifest.json at ${baseRefRaw} was not valid JSON`);
        }
      }
    }
  }
} else {
  warnings.push("not a git repository — append-only check skipped (seal hashes still verified against disk)");
}

if (errors.length) {
  for (const e of errors) console.error(`archived: ${e}`);
  process.exit(1);
}

if (isWrite) {
  const sorted = Object.fromEntries(Object.entries(manifest.files).sort(([a], [b]) => a.localeCompare(b)));
  writeFileSync(manifestPath, JSON.stringify({ version: 1, files: sorted }, null, 2) + "\n", "utf8");
}

for (const w of warnings) console.warn(`warning: ${w}`);
console.log(`ok: ${files.length} archived note(s) verified, ${Object.keys(manifest.files).length} seal(s) in manifest`);
