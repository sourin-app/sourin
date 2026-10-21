#!/usr/bin/env node
/**
 * notes-gate：把三个 verify 脚本包成一道**会红**的门禁。
 *
 * ## 为什么需要这层壳
 *
 * `verify-agent-note-tree.ts` / `verify-agent-note-format.ts` /
 * `verify-archived-agent-notes.ts` 在**空集合**上都 `exit 0`：
 * 笔记树整个不存在时，它们会打印 `ok: 0 note(s)` 然后成功退出。
 * 这不是它们的 bug（对「这个仓库还没有笔记」是合理语义），
 * 但对 CI 是灾难：把笔记目录改名、删掉，或者脚本的 glob 写错只匹配到 0 个文件，
 * **三道门禁同时变绿**，而它们本来要挡的东西一件都没挡。
 *
 * 所以这里只加一条判据：**笔记树里一篇笔记都没有 ⇒ 失败。**
 * 其余判定完全交给上游脚本 —— 本文件不复制它们的规则，
 * 免得出现「壳里的规则与脚本里的规则各说一套」。
 *
 * ## 为什么顺手做 runner 探测
 *
 * CI 用 `npx --yes tsx`（本仓没有 package.json，不引入 node_modules）；
 * 本地 Node 22.6+ 能原生执行 .ts（type stripping），直接 `node x.ts` 更快且离线。
 * 探测一次、结果缓存在本次进程里，两种环境都能跑同一条命令。
 *
 * ## 用法
 *
 *   node .agents/notes-scripts/notes-gate.mjs
 *
 * 退出码：0=三道全过；1=任一道红或树为空；2=无法判定（找不到脚本等）。
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const NOTES_ROOT = process.env.AGENT_NOTE_ROOT || ".agents/notes";
const SCRIPTS_DIR = ".agents/notes-scripts";

/** 三道门禁，按「越基础越先跑」的顺序。 */
const GATES = [
  "verify-agent-note-tree.ts",
  "verify-agent-note-format.ts",
  "verify-archived-agent-notes.ts",
];

/**
 * 递归数笔记篇数。
 *
 * 只数 `.md`，不区分 lifecycle/class —— 这里要回答的是
 * 「门禁有没有东西可查」，不是「目录结构对不对」（那是 tree gate 的事）。
 *
 * @param {string} dir 起始目录。
 * @returns {number} 篇数。
 */
function countNotes(dir) {
  if (!existsSync(dir)) return 0;
  let total = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) total += countNotes(full);
    else if (entry.isFile() && entry.name.endsWith(".md")) total += 1;
  }
  return total;
}

/**
 * 探测本机 node 能否直接跑 .ts。
 *
 * 判据是**真跑一个带类型标注的临时文件**，不是读 `process.version`：
 * Node 22.6 起类型剥离是实验性开关、23+ 默认开、未来还可能再变；
 * 版本号判断迟早与现实脱节，而跑一次文件不会。
 *
 * @returns {'node'|'tsx'} 用哪种 runner。
 */
function detectRunner() {
  if (process.env.NOTES_RUNNER === "node" || process.env.NOTES_RUNNER === "tsx") {
    return process.env.NOTES_RUNNER;
  }
  const dir = mkdtempSync(join(tmpdir(), "notes-runner-"));
  try {
    const probe = join(dir, "probe.ts");
    writeFileSync(probe, "const n: number = 1;\nif (n !== 1) throw new Error('no');\n", "utf8");
    const result = spawnSync(process.execPath, [probe], { encoding: "utf8", windowsHide: true });
    return result.status === 0 ? "node" : "tsx";
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * 用给定 runner 跑一个脚本，把输出直接透传给 CI 日志。
 *
 * `stdio: 'inherit'` 是有意的：门禁的失败原因要出现在日志里，
 * 捕获到自己手上再打印会把多行诊断压成一行。
 *
 * @param {'node'|'tsx'} runner runner。
 * @param {string} script 脚本路径。
 * @returns {number} 退出码（非 0 已在调用处判红）。
 */
function runGate(runner, script) {
  const [cmd, args] =
    runner === "node"
      ? [process.execPath, [script]]
      : ["npx", ["--yes", "tsx", script]];
  const result = spawnSync(cmd, args, {
    stdio: "inherit",
    cwd: process.cwd(),
    windowsHide: true,
    shell: process.platform === "win32" && cmd === "npx"
  });
  return result.status ?? 2;
}

const notesDir = resolve(process.cwd(), NOTES_ROOT);
const notesCount = countNotes(notesDir);

if (notesCount === 0) {
  console.error(`notes-gate: ${NOTES_ROOT} 里一篇笔记都没有 —— 三个 verify 脚本在空集合上都会 exit 0，`);
  console.error(`notes-gate: 那意味着这道门禁什么都没查。要么把笔记树放回来，要么先改 AGENT_NOTE_ROOT。`);
  process.exit(1);
}

const missing = GATES.filter((name) => !existsSync(join(process.cwd(), SCRIPTS_DIR, name)));
if (missing.length > 0) {
  console.error(`notes-gate: 缺少门禁脚本：${missing.join(", ")}（在 ${SCRIPTS_DIR} 下）`);
  process.exit(2);
}

const runner = detectRunner();
console.error(`notes-gate: ${notesCount} 篇笔记，runner=${runner}`);

for (const name of GATES) {
  const script = join(SCRIPTS_DIR, name);
  const code = runGate(runner, script);
  if (code !== 0) {
    console.error(`notes-gate: ${name} 退出码 ${code} —— 门禁红`);
    process.exit(code === 0 ? 2 : code);
  }
}

console.log(`notes-gate: 三道门禁全部通过（${notesCount} 篇笔记）`);
