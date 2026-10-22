#!/usr/bin/env node
/**
 * notes-selftest：证明这几道笔记门禁**真的会红**。
 *
 * ## 为什么需要它
 *
 * 2026-10-22 在真实项目里实测出两个「门禁静默放行」的缺陷：
 *
 *   1. `notes-supersession.mjs` 的链接正则只认 `[a](b.md)`，
 *      于是 `[a](<b.md>)` 与 `[a](b.md "title")`（两种合法写法）
 *      被判成「没写链接」—— **合规的笔记被拒**，提示还让人去加链接。
 *   2. `verify-archived-agent-notes.ts` 对「基线查不到」一律 `catch {}` 放行，
 *      于是基线 ref 拼错、全零 sha（CI 新分支 push 的 `github.event.before`）、
 *      不在 git 仓库里，三种情况都 `exit 0` 并打印 `ok: 1 archived note(s)`。
 *
 * 两个缺陷的共同点：**没有任何测试会让它们变红**。门禁写错时，
 * 唯一的反馈是「它太宽松了」或「它拒绝了合法输入」，而这两种都表现为
 * 一个看起来正常的退出码。所以这个文件的存在意义不是覆盖率，
 * 而是把「这道门禁会红」变成可执行的事实。
 *
 * ## 判据取向
 *
 * 每个用例都断言**具体的退出码**，不做「非零就行」的模糊判断 ——
 * 一个因为参数拼错而崩溃的脚本也返回非零，那会把真缺陷盖住。
 * 正向用例（应当 0）与反向用例（应当非 0）成对出现：只有反向用例能证明
 * 门禁不是恒绿，只有正向用例能证明它不是恒红。
 *
 * ## 用法
 *
 *   node .agents/notes-scripts/notes-selftest.mjs
 *
 * 退出码：0=全部用例符合预期；1=有用例不符合。
 */
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync
} from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const SCRIPTS = ".agents/notes-scripts";

/**
 * 探测本机 node 能否直接跑 .ts（与 notes-gate.mjs 同一判据：真跑一个文件）。
 *
 * @returns {'node'|'tsx'} runner。
 */
function detectRunner() {
  if (process.env.NOTES_RUNNER === "node" || process.env.NOTES_RUNNER === "tsx") {
    return process.env.NOTES_RUNNER;
  }
  const dir = mkdtempSync(join(tmpdir(), "notes-selftest-runner-"));
  try {
    const probe = join(dir, "probe.ts");
    writeFileSync(probe, "const n: number = 1;\nif (n !== 1) throw new Error('no');\n", "utf8");
    return spawnSync(process.execPath, [probe], { encoding: "utf8", windowsHide: true }).status === 0
      ? "node"
      : "tsx";
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const runner = detectRunner();

/** 已执行命令的日志，用例失败时打印出来 —— 否则只看到「✖ 名称」，不知道门禁说了什么。 */
const commandLog = [];

/**
 * 跑一个命令，返回退出码。
 *
 * @param {string} cmd 可执行文件。
 * @param {string[]} args 参数。
 * @param {object} [options] cwd 与 env。
 * @returns {number} 退出码（崩溃/超时按 2）。
 */
function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    cwd: options.cwd,
    env: { ...process.env, ...(options.env ?? {}) },
    encoding: "utf8",
    windowsHide: true,
    shell: process.platform === "win32" && cmd === "npx"
  });
  const status = result.status ?? 2;
  commandLog.push({
    label: `${cmd === process.execPath ? "node" : cmd} ${args.map((a) => (a.includes("/") || a.includes("\\") ? a.split(/[\\/]/).pop() : a)).join(" ")}`,
    status,
    out: String(result.stdout ?? "").trim(),
    err: String(result.stderr ?? "").trim()
  });
  return status;
}

/**
 * 跑一个 .ts 门禁脚本。
 *
 * @param {string} cwd 仓库根。
 * @param {string} script 脚本名（在 SCRIPTS 下）。
 * @param {object} [options] env。
 * @returns {number} 退出码。
 */
function gate(cwd, script, options = {}) {
  const path = join(cwd, SCRIPTS, script);
  return runner === "node"
    ? run(process.execPath, [path], { cwd, env: options.env })
    : run("npx", ["--yes", "tsx", path], { cwd, env: options.env });
}

/**
 * 跑 .mjs 门禁脚本。
 *
 * @param {string} cwd 仓库根。
 * @param {string} script 脚本名（在 SCRIPTS 下）。
 * @param {object} [options] env。
 * @returns {number} 退出码。
 */
function mjsGate(cwd, script, options = {}) {
  return run(process.execPath, [join(cwd, SCRIPTS, script)], { cwd, env: options.env });
}

/**
 * 在夹具里跑 git（带上内联身份，避免依赖全局配置）。
 *
 * @param {string} cwd 仓库根。
 * @param {string[]} args git 参数。
 * @returns {string} stdout。
 */
function git(cwd, args) {
  const result = spawnSync(
    "git",
    ["-c", "user.email=selftest@example.invalid", "-c", "user.name=selftest", "-c", "commit.gpgsign=false", ...args],
    { cwd, encoding: "utf8", windowsHide: true }
  );
  if (result.status !== 0) throw new Error(`git ${args.join(" ")} 失败：${result.stderr}`);
  return String(result.stdout ?? "");
}

/** 用例登记表。 */
const cases = [];

/**
 * 登记一个用例。
 *
 * @param {string} name 用例名。
 * @param {() => boolean} body 返回 true 表示符合预期。
 */
function test(name, body) {
  cases.push({ name, body });
}

const NOTES = ".agents/notes";

/**
 * 写一篇笔记。
 *
 * @param {string} root 仓库根。
 * @param {string} rel 相对 NOTES 的路径。
 * @param {string} text 内容。
 */
function writeNote(root, rel, text) {
  const full = join(root, NOTES, rel);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, text, "utf8");
}

/** 一个格式合法的 implemented 笔记（最小可过 format gate 的骨架）。 */
function implementedNote(title, extra = "") {
  return [
    `# Agent Note: ${title}`,
    "",
    "Status: implemented",
    "",
    "## Problem",
    "",
    "自测夹具：这段文本只用来让门禁有东西可读。",
    "",
    "## Decision",
    "",
    "自测夹具：Decision 段存在。",
    "",
    "## Alternatives considered",
    "",
    "- **不做** — 夹具不需要真的权衡，只需要过格式。",
    "",
    "## Consequences",
    "",
    "- **收益**：夹具可跑。",
    "",
    ...(extra ? [extra, ""] : [])
  ].join("\n");
}

/** 一个格式合法的 archived 笔记（archived 要求在 Status 下紧邻 Archived 行）。 */
function archivedNote(title) {
  return [
    `# Agent Note: ${title}`,
    "",
    "Status: implemented",
    "Archived: 2026-01-05",
    "",
    "## Problem",
    "",
    "自测夹具：archived 笔记。",
    "",
    "## Decision",
    "",
    "自测夹具：已封存。",
    "",
    "## Alternatives considered",
    "",
    "- **不封存** — 夹具不需要真的权衡。",
    "",
    "## Consequences",
    "",
    "- **收益**：封印有内容可哈希。",
    ""
  ].join("\n");
}

/**
 * 计算封印值（与 archive-agent-note.ts 同格式：`sha256:<hex>`，哈希文件字节）。
 *
 * @param {string} path 文件路径。
 * @returns {string} 封印值。
 */
function sealOf(path) {
  return `sha256:${createHash("sha256").update(readFileSync(path)).digest("hex")}`;
}

// ── 建夹具 ────────────────────────────────────────────────────────────
const root = mkdtempSync(join(tmpdir(), "notes-selftest-"));
try {
  cpSync(SCRIPTS, join(root, SCRIPTS), { recursive: true });
  process.env.NOTES_RUNNER = runner;

  writeNote(root, "implemented/process/2026-01-01-base.md", implementedNote("基线笔记"));
  git(root, ["init", "-q"]);
  git(root, ["add", "-A"]);
  git(root, ["commit", "-qm", "base"]);

  // ── supersession：三种合法链接写法都必须被认出来 ────────────────────
  const linkForms = [
    ["普通写法 [a](b.md)", "[基线](../process/2026-01-01-base.md)"],
    ["尖括号写法 [a](<b.md>)", "[基线](<../process/2026-01-01-base.md>)"],
    ['带标题写法 [a](b.md "title")', '[基线](../process/2026-01-01-base.md "标题")']
  ];
  for (const [label, link] of linkForms) {
    test(`supersession 认得出${label}`, () => {
      const rel = "implemented/process/2026-01-02-link.md";
      writeNote(root, rel, implementedNote("带链接的新笔记", `见 ${link}。`));
      git(root, ["add", "-A"]);
      const code = mjsGate(root, "notes-supersession.mjs");
      git(root, ["reset", "-q"]);
      rmSync(join(root, NOTES, rel));
      return code === 0;
    });
  }

  test("supersession 对真正没声明的笔记必须红（否则上面三条毫无意义）", () => {
    const rel = "implemented/process/2026-01-02-bare.md";
    writeNote(root, rel, implementedNote("既没有链接也没有 Independent"));
    git(root, ["add", "-A"]);
    const code = mjsGate(root, "notes-supersession.mjs");
    git(root, ["reset", "-q"]);
    rmSync(join(root, NOTES, rel));
    return code === 1;
  });

  test("supersession 认 Independent: 声明", () => {
    const rel = "implemented/process/2026-01-02-indep.md";
    writeNote(root, rel, implementedNote("独立笔记", "Independent: 与既有决定无关，因为主题不同。"));
    git(root, ["add", "-A"]);
    const code = mjsGate(root, "notes-supersession.mjs");
    git(root, ["reset", "-q"]);
    rmSync(join(root, NOTES, rel));
    return code === 0;
  });

  test("supersession 豁免 proposed/（还没落地，不该被逼挂靠）", () => {
    const rel = "proposed/feature/2026-01-02-draft.md";
    writeNote(root, rel, implementedNote("草稿"));
    git(root, ["add", "-A"]);
    const code = mjsGate(root, "notes-supersession.mjs");
    git(root, ["reset", "-q"]);
    rmSync(join(root, NOTES, rel));
    return code === 0;
  });

  // ── tree / format：证明它们不是恒绿 ──────────────────────────────────
  test("format 门禁对缺 ## Decision 的笔记必须红", () => {
    const rel = "implemented/process/2026-01-03-broken.md";
    writeNote(root, rel, "# Agent Note: 缺段\n\nStatus: implemented\n\n## Problem\n\n只有 Problem。\n");
    const code = gate(root, "verify-agent-note-format.ts");
    rmSync(join(root, NOTES, rel));
    return code === 1;
  });

  test("tree 门禁对非法 class 目录必须红", () => {
    const rel = "implemented/wrong-class/2026-01-03-x.md";
    writeNote(root, rel, implementedNote("非法 class"));
    const code = gate(root, "verify-agent-note-tree.ts");
    rmSync(join(root, NOTES, "implemented/wrong-class"), { recursive: true, force: true });
    return code === 1;
  });

  // ── format：行内代码里的注释起始符不许把遮蔽吃穿 ─────────────────────
  // 2026-10-22 的真红：一篇记录 `<!--` 语法的笔记，把这串字符写在行内代码里，
  // 而 maskSource 当时只挡围栏、不挡行内代码 ⇒ inComment 一路吃到文末 ⇒
  // 后面明明写着的 ## Consequences 被判成注释行，门禁报「缺 Consequences」。
  test("format 门禁：行内代码里的 <!-- 不算注释开头（正向对照）", () => {
    const rel = "implemented/bug-fix/2026-01-04-inline-code.md";
    const text = [
      "# Agent Note: 行内代码里写着注释起始符",
      "",
      "Status: implemented",
      "",
      "## Problem",
      "",
      "这篇笔记要记录 `<!--` 这个语法，但它写在反引号里，后面没有闭合的 `-->`。",
      "",
      "## Decision",
      "",
      "自测夹具：行内代码应当被遮蔽成空格，状态机不受影响。",
      "",
      "## Alternatives considered",
      "",
      "- **不做** — 夹具只需要过格式。",
      "",
      "## Consequences",
      "",
      "- **收益**：夹具可跑。",
      ""
    ].join("\n");
    writeNote(root, rel, text);
    const code = gate(root, "verify-agent-note-format.ts");
    rmSync(join(root, NOTES, rel));
    return code === 0;
  });

  test("format 门禁：真的未闭合注释仍要遮住后面的小节（反向对照）", () => {
    const rel = "implemented/bug-fix/2026-01-04-real-comment.md";
    const text = [
      "# Agent Note: 忘记收尾的注释",
      "",
      "Status: implemented",
      "",
      "## Problem",
      "",
      "<!-- 这里开始一段忘记收尾的注释",
      "",
      "## Decision",
      "",
      "这段落在注释里，门禁应当看不见它。",
      "",
      "## Alternatives considered",
      "",
      "- **不做** — 夹具。",
      "",
      "## Consequences",
      "",
      "- **收益**：夹具可跑。",
      ""
    ].join("\n");
    writeNote(root, rel, text);
    const code = gate(root, "verify-agent-note-format.ts");
    rmSync(join(root, NOTES, rel));
    return code === 1;
  });

  // ── archived：封印与基线 ────────────────────────────────────────────
  const archivedRel = "archived/process/2026-01-05-old.md";
  writeNote(root, archivedRel, archivedNote("已封存笔记"));
  const manifestPath = join(root, NOTES, "archived", "manifest.json");
  const writeManifest = (files) =>
    writeFileSync(manifestPath, `${JSON.stringify({ version: 1, files }, null, 2)}\n`, "utf8");
  writeManifest({ [archivedRel]: sealOf(join(root, NOTES, archivedRel)) });
  git(root, ["add", "-A"]);
  git(root, ["commit", "-qm", "sealed"]);
  const sealedCommit = git(root, ["rev-parse", "HEAD"]).trim();

  test("archived 门禁在封印与基线一致时通过（正向对照）", () => {
    return gate(root, "verify-archived-agent-notes.ts", { env: { AGENT_NOTE_ARCHIVE_BASE_REF: sealedCommit } }) === 0;
  });

  test("archived 门禁对全零基线必须红（CI 新分支 push 的 event.before）", () => {
    const zeros = "0".repeat(40);
    return gate(root, "verify-archived-agent-notes.ts", { env: { AGENT_NOTE_ARCHIVE_BASE_REF: zeros } }) === 1;
  });

  test("archived 门禁对拼错的基线 ref 必须红", () => {
    return gate(root, "verify-archived-agent-notes.ts", {
      env: { AGENT_NOTE_ARCHIVE_BASE_REF: "refs/heads/definitely-not-a-branch" }
    }) === 1;
  });

  test("archived 门禁在封印相对基线被改写时必须红（磁盘封印同步更新，只有基线能发现）", () => {
    const sealedAbs = join(root, NOTES, archivedRel);
    const before = readFileSync(sealedAbs, "utf8");
    const after = `${before}\n多出来的一行：这改变了文件内容，但没有改变"当前 manifest 与磁盘一致"这个事实。\n`;
    writeFileSync(sealedAbs, after, "utf8");
    writeManifest({ [archivedRel]: sealOf(sealedAbs) }); /* 让当前侧自洽，只剩基线可比 */
    const code = gate(root, "verify-archived-agent-notes.ts", { env: { AGENT_NOTE_ARCHIVE_BASE_REF: sealedCommit } });
    writeFileSync(sealedAbs, before, "utf8");
    writeManifest({ [archivedRel]: sealOf(sealedAbs) });
    return code === 1;
  });

  test("archived 门禁对基线里坏掉的 manifest 必须红", () => {
    const dir = join(root, NOTES, "archived");
    const saved = readFileSync(manifestPath, "utf8");
    writeFileSync(manifestPath, "{ this is not json\n", "utf8");
    git(root, ["add", "-A"]);
    git(root, ["commit", "-qm", "broken manifest"]);
    const brokenCommit = git(root, ["rev-parse", "HEAD"]).trim();
    writeFileSync(manifestPath, saved, "utf8");
    git(root, ["add", "-A"]);
    git(root, ["commit", "-qm", "restore manifest"]);
    const code = gate(root, "verify-archived-agent-notes.ts", { env: { AGENT_NOTE_ARCHIVE_BASE_REF: brokenCommit } });
    return code === 1;
  });

  // ── notes-gate：空集合必须红 ────────────────────────────────────────
  test("notes-gate 在笔记树为空时必须红（三道脚本自己会 exit 0）", () => {
    const empty = ".agents/notes-empty-for-selftest";
    mkdirSync(join(root, empty), { recursive: true });
    const code = mjsGate(root, "notes-gate.mjs", { env: { AGENT_NOTE_ROOT: empty } });
    rmSync(join(root, empty), { recursive: true, force: true });
    return code === 1;
  });

  test("notes-gate 在正常树上必须绿（否则上面那条只证明了它会崩）", () => {
    return mjsGate(root, "notes-gate.mjs") === 0;
  });

  // ── 执行 ────────────────────────────────────────────────────────────
  let failed = 0;
  for (const { name, body } of cases) {
    let ok = false;
    let error = "";
    const logFrom = commandLog.length;
    try {
      ok = body() === true;
    } catch (e) {
      error = ` — 异常：${e && e.message ? e.message : String(e)}`;
    }
    if (!ok) failed += 1;
    console.log(`${ok ? "✔" : "✖"} ${name}${ok ? "" : error}`);
    if (!ok) {
      /* 失败的用例要把门禁自己说的话贴出来：只有退出码的话，
         「预期 0 实得 1」和「预期 1 实得 0」都看不出是门禁判错了还是夹具写错了。 */
      for (const entry of commandLog.slice(logFrom)) {
        console.log(`    · ${entry.label} → exit ${entry.status}`);
        for (const line of [entry.out, entry.err].filter(Boolean).join("\n").split("\n").slice(0, 6)) {
          console.log(`      ${line}`);
        }
      }
    }
  }
  console.log(`\nnotes-selftest: ${cases.length - failed}/${cases.length} 通过（runner=${runner}）`);
  process.exitCode = failed === 0 ? 0 : 1;
} finally {
  rmSync(root, { recursive: true, force: true });
}
