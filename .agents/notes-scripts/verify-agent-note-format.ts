/**
 * Enforce Agent Note headers, lifecycle-specific sections, alternatives.
 * Implemented notes may not carry proposal-era H2s; present tense in the
 * body is a prose rule, not a lexical scan.
 * Run: npx tsx <skill-dir>/scripts/verify-agent-note-format.ts
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { agentNoteRoot, walkAgentNoteTree } from "./agent-note-tree.ts";

const STATUS: Record<string, RegExp> = {
  proposed: /^Status: proposed$|^状态[:：] ?(?:proposed|已提议)$/,
  implemented: /^Status: implemented$|^状态[:：] ?(?:implemented|已实现)$/,
  rejected: /^Status: rejected — .+$|^状态[:：] ?(?:rejected|已否决) — .+$/,
};

const PROBLEM_FIRST = ["## Problem", "## 问题"];

const REQUIRED: Record<string, string[][]> = {
  proposed: [
    ["## Proposal", "## 提议", "## 方案", "## 提案"],
    ["## Acceptance criteria", "## 验收标准", "## 验收条件", "## 接受标准"],
    ["## Risks", "## 风险"],
  ],
  implemented: [
    ["## Decision", "## 决定", "## 决策"],
    ["## Consequences", "## 后果", "## 影响", "## 结果", "## 结果与代价", "## 影响与验证", "## 后果与边界"],
  ],
  rejected: [
    ["## Proposal", "## 提议", "## 方案", "## 提案"],
  ],
};

const BANNED_IMPLEMENTED = new Set([
  "## proposal", "## plan", "## migration plan", "## acceptance criteria",
  "## 提议", "## 方案", "## 提案",
  "## 计划", "## 规划", "## 迁移计划",
  "## 验收标准", "## 验收条件", "## 接受标准",
]);

const ALTERNATIVES_RE = /^## (?:Alternatives considered|.{0,8}?(?:替代方案|备选(?:方案)?|其他做法))$/;
const FORMAT_ADOPTED = "2026-07-05";
const GRANDFATHER = "<!-- agent-note-format: alternatives-not-recorded (pre-format Agent Note) -->";

/** Strip trailing parenthetical: `## Decision（说明）` → `## Decision`. */
function headingBase(h: string): string {
  return h.replace(/[（(].*$/, "").trimEnd();
}

interface MaskedSource {
  lines: string[];
  /** line indexes inside fenced code blocks */
  fenced: boolean[];
  /** line indexes inside HTML comments */
  commented: boolean[];
}

/**
 * Blank out inline code spans (`` `x` ``, ``` ``x`` ```) with spaces, preserving
 * length so byte offsets still line up.
 *
 * ★ 为什么必须做：一篇笔记**记录** `<!--` 这个语法时，它会把这串字符写在行内
 * 代码里。不遮蔽行内代码，`l.indexOf("<!--")` 就把行内代码当成真注释的开头，
 * 于是 `inComment` 一路吃到文末 —— 后面所有 `## 小节` 全被判成注释行，
 * 门禁报「缺 ## Consequences」，而笔记明明写了。
 * 2026-10-22 实测：`2026-10-22-release-notes-renderer-shows-markup-as-text.md`
 * 的第 70、78 行各有一个未闭合的行内 `<!--`，CI 因此变红，本地也红。
 * 遮蔽后行号与偏移都不变，报错指的行还是原文件那一行。
 */
function blankInlineCode(line: string): string {
  let out = "";
  let i = 0;
  while (i < line.length) {
    if (line[i] !== "`") {
      out += line[i];
      i++;
      continue;
    }
    let ticks = 0;
    while (line[i + ticks] === "`") ticks++;
    const fence = "`".repeat(ticks);
    // 闭合用的反引号串必须等长（`` ` `` 与 ``` `` ``` 不是同一种围栏）。
    const close = line.indexOf(fence, i + ticks);
    if (close === -1) {
      // 未闭合的反引号按字面处理（与 Markdown 一致），不吞掉本行其余内容。
      out += line.slice(i, i + ticks);
      i += ticks;
      continue;
    }
    out += " ".repeat(close + ticks - i);
    i = close + ticks;
  }
  return out;
}

/** Normalize BOM/CRLF, then mask fenced code and HTML comment regions. */
function maskSource(raw: string): MaskedSource {
  const normalized = raw.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const fenced = new Array<boolean>(lines.length).fill(false);
  const commented = new Array<boolean>(lines.length).fill(false);
  let inFence = false;
  let inComment = false;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    // 行内代码先抹成等长空格：反引号里的 `<!--` / ``` ``` ``` 都不该改变状态机。
    const scan = blankInlineCode(l);
    fenced[i] = inFence;
    commented[i] = inComment;
    // A fence opens/closes only on its own line (≤3 leading spaces); fence
    // mentions inside inline code or prose never toggle state.
    if (!inComment && /^\s{0,3}```/.test(scan)) {
      fenced[i] = true;
      inFence = !inFence;
    } else if (inFence) {
      fenced[i] = true;
    }
    // Fence interiors are opaque: a `<!--` in a HTML/JSX sample must not
    // leak the comment mask past the closing fence.
    if (inFence) continue;
    const openIdx = inComment ? -1 : scan.indexOf("<!--");
    const closeIdx = scan.indexOf("-->");
    if (inComment) {
      commented[i] = true;
      if (closeIdx !== -1) inComment = false;
    } else if (openIdx !== -1) {
      commented[i] = true;
      if (closeIdx === -1 || closeIdx < openIdx) inComment = true;
    }
  }
  return { lines, fenced, commented };
}

function isProseLine(src: MaskedSource, i: number): boolean {
  if (src.fenced[i] || src.commented[i]) return false;
  return !/^\s*>/.test(src.lines[i]);
}

const { notes, errors } = walkAgentNoteTree();

for (const note of notes) {
  const fail = (msg: string) => { errors.push(`format: ${note.rel} — ${msg}`); };
  const src = maskSource(readFileSync(resolve(agentNoteRoot, note.rel), "utf8"));
  const { lines } = src;
  const proseIdx: number[] = [];
  for (let i = 0; i < lines.length; i++) if (isProseLine(src, i)) proseIdx.push(i);
  const prose = proseIdx.map((i) => lines[i]);

  // Halfwidth or fullwidth colon (IME often inserts ：)
  if (!/^# Agent Note[:：] ?\S/.test(lines[0] ?? "")) fail("line 1 must be `# Agent Note: <title>`");
  if (lines[1] !== "") fail("line 2 must be blank");

  const re = STATUS[note.lifecycle];
  if (re && !re.test(lines[2] ?? "")) fail(`line 3 must match ${note.lifecycle} status grammar (${String(re)})`);
  if (lines[3] !== "") fail("line 4 must be blank");

  // single Status line (fences, quotes and comments immune). Match strict
  // status-shaped lines only — body prose like "Status: 200 means OK" must
  // not be miscounted as a duplicate status header.
  const looksLikeStatusLine = (l: string) => {
    const t = l.trim();
    return Object.values(STATUS).some((re) => re.test(t));
  };
  const statusCount = prose.filter(looksLikeStatusLine).length;
  if (statusCount !== 1) fail("Status: line must appear exactly once");

  const h2s = prose.filter((l: string) => l.startsWith("## ")).map((l: string) => l.trimEnd());
  const bases = h2s.map(headingBase);
  if (!PROBLEM_FIRST.includes(headingBase(h2s[0] ?? ""))) {
    fail(`first section must be ## Problem or ## 问题 (got ${JSON.stringify(h2s[0] ?? "<none>")})`);
  }

  for (const group of REQUIRED[note.lifecycle] ?? []) {
    if (!group.some((h: string) => bases.includes(h))) fail(`missing one of ${JSON.stringify(group)}`);
  }

  if (note.lifecycle === "implemented") {
    for (const h of bases.filter((x: string) => BANNED_IMPLEMENTED.has(x.toLowerCase()))) {
      fail(`banned in implemented: ${h}`);
    }
  }

  const hasSection = bases.some((h: string) => ALTERNATIVES_RE.test(h));
  const rawText = readFileSync(resolve(agentNoteRoot, note.rel), "utf8");
  const hasGrandfather = rawText.includes(GRANDFATHER);
  if (hasSection && hasGrandfather) fail("carries both ## Alternatives considered and grandfather comment — drop the comment");
  if (!hasSection && !hasGrandfather) {
    fail("missing ## Alternatives considered / ## 备选方案");
  }
  if (hasGrandfather && note.date >= FORMAT_ADOPTED) fail(`grandfather comment only valid before ${FORMAT_ADOPTED}`);
}

if (errors.length) {
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log(`ok: ${notes.length} note(s) verified`);
