#!/usr/bin/env node
/**
 * Supersession 检查：新笔记必须声明它与既有笔记的关系。
 *
 * ## 为什么需要（借鉴 DSH 的硬规则）
 *
 * `deepseek-ai/deepseek-harness` 的 `.agents/notes/AGENTS.md` 第一句就是：
 *
 * > **Every new Agent Note triggers a supersession check.**
 *
 * 它要求：写新笔记前搜索活跃笔记树，判定「完全取代 / 部分取代 / 无关」，
 * 完全取代的必须在**同一个 PR** 里归档旧篇。
 *
 * 本插件原先完全没有这个机制。实测本仓库 11 篇笔记里只有 3 篇有互链 ——
 * 不是作者懒，而是**没有任何东西会提醒他去看**。笔记越多，
 * 重复的决定与已过期的结论就越多，而没有人会发现。
 *
 * ## 为什么不做成「语义判重」
 *
 * 判断「这两篇讲的是不是同一个决定」需要理解内容，做不到可靠。
 * 硬做会产出大量误报，而误报的门禁会被绕过（详见 notes-coverage 的取舍）。
 *
 * 所以这里只做**可机械验证的最低要求**：新笔记必须至少满足其一 ——
 *
 *   1. 与既有笔记有相对链接（表示它接在某个决定之后）；
 *   2. 正文声明 `Independent: <理由>`（表示确实与现有决定无关）；
 *   3. 它本身是 `proposed` / `rejected`（想法与否定阶段允许孤立，
 *      因为它们还没成为「已落地的决定」，不该被迫挂靠）。
 *
 * 第 2 条是关键设计：**它把「我查过了」变成可验证的动作**。
 * 写 `Independent:` 的人必须给出理由，而给理由这件事本身就会促使他真去查一遍。
 *
 * ## 用法
 *
 *   node tools/notes-supersession.mjs                 # 检查暂存区新增的笔记
 *   node tools/notes-supersession.mjs --range A..B    # 检查提交区间
 *
 * 退出码：0=通过；1=有新增笔记未声明关系；2=无法判定。
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * git 输出的上限。`spawnSync` 默认 1MB，大仓库会超。
 * 取值与 notes-coverage.mjs / deepseek-harness 的 change-scope.ts 一致。
 */
const MAX_GIT_OUTPUT = 64 * 1024 * 1024;

/**
 * 跑 git 并返回 stdout。
 *
 * `maxBuffer` 显式放大：超限时 `status` 为 `null`（会走失败分支，不会假绿），
 * 但会误报「无法判定」，让门禁在大仓库上不可用。
 *
 * @param {string[]} args git 参数。
 * @returns {{ ok: boolean, out: string, err: string }} 结果。
 */
function git(args) {
  const result = spawnSync('git', args, {
    cwd: process.cwd(),
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: MAX_GIT_OUTPUT
  });
  return {
    ok: result.status === 0,
    out: String(result.stdout ?? ''),
    err: String(result.stderr ?? '')
  };
}

/**
 * 按行切分并去掉空项。
 *
 * @param {string} text 原始输出。
 * @returns {string[]} 行列表。
 */
function splitLines(text) {
  return text.split('\n').map((line) => line.trim()).filter((line) => line !== '');
}

/**
 * 从 `git diff --name-status -z` 的 NUL 分隔输出解析出「新增」的文件路径。
 *
 * 只关心 A（新增）：修改既有笔记不需要再做 supersession 检查 ——
 * 它本来就有归属。
 *
 * ## 为什么必须用 -z
 *
 * 不带 `-z` 时 git 会把非 ASCII 路径转义成 `"lib/\344\270\255..."` 并加引号，
 * 于是 `endsWith('.md')` 之类的判断会失败 ⇒ 中文文件名的笔记**静默逃检**。
 * 这是实测发现的真缺陷（在 notes-coverage 里同源），不是理论风险。
 *
 * `-z` 的记录格式：`状态\0路径\0`（改名是 `R100\0旧\0新\0`）。
 *
 * @param {string} text NUL 分隔的原始输出。
 * @returns {string[]} 新增文件路径。
 */
function addedPathsZ(text) {
  const records = text.split('\u0000').filter((entry) => entry !== '');
  const out = [];
  let index = 0;
  while (index < records.length) {
    const status = records[index];
    index += 1;
    if (status.startsWith('R') || status.startsWith('C')) {
      /* 改名/复制：旧路径跳过，取新路径。改名不算「新增笔记」——
         它本来就有归属，不该触发 supersession 检查。 */
      index += 2;
      continue;
    }
    if (index < records.length) {
      if (status.startsWith('A')) out.push(records[index]);
      index += 1;
    }
  }
  return out;
}

/**
 * 读取配置（复用 notes-coverage 的配置文件约定）。
 *
 * @param {string} repoRoot 仓库根。
 * @returns {{noteDirs: string[], error?: string}} 笔记目录。
 */
function loadNoteDirs(repoRoot) {
  const file = join(repoRoot, '.agents', 'notes-coverage.json');
  if (!existsSync(file)) return { noteDirs: ['.agents/notes'] };
  try {
    const raw = JSON.parse(readFileSync(file, 'utf8'));
    if (Array.isArray(raw?.noteDirs) && raw.noteDirs.every((v) => typeof v === 'string')) {
      return { noteDirs: raw.noteDirs };
    }
    return { noteDirs: ['.agents/notes'] };
  } catch (error) {
    return { noteDirs: [], error: `读取 ${file} 失败：${error.message}` };
  }
}

/**
 * 判断一个路径是不是笔记文件。
 *
 * @param {string} path 仓库相对路径。
 * @param {string[]} noteDirs 笔记目录。
 * @returns {boolean} 是否笔记。
 */
function isNote(path, noteDirs) {
  if (!path.endsWith('.md')) return false;
  return noteDirs.some((dir) => path.startsWith(`${dir.replace(/\/$/, '')}/`));
}

/**
 * 判断笔记是否处于「还没落地」的阶段。
 *
 * `proposed` 是想法、`rejected` 是否定 —— 两者都还没成为已落地的决定，
 * 不该被迫挂靠到既有笔记上。
 *
 * @param {string} path 仓库相对路径。
 * @returns {boolean} 是否豁免。
 */
function isDraft(path) {
  return /\/proposed\//.test(path) || /\/rejected\//.test(path);
}

/**
 * 检查一篇笔记是否声明了与既有笔记的关系。
 *
 * @param {string} repoRoot 仓库根。
 * @param {string} path 笔记的相对路径。
 * @returns {{ok: boolean, reason: string}} 判定结果。
 */
function declaresRelation(repoRoot, path) {
  const full = resolve(repoRoot, path);
  let text;
  try {
    text = readFileSync(full, 'utf8');
  } catch {
    /* 读不到就当作未声明 —— 保守方向。 */
    return { ok: false, reason: '读不到文件内容' };
  }

  /* ① 相对链接：指向笔记树里的另一篇。
     只认 `.md` 结尾的相对链接，避免把外部 URL 或图片算进来。

     must：要覆盖 markdown 的三种合法写法，否则「写了链接却被判没有」：
       [a](b.md)             普通
       [a](<b.md>)           尖括号包裹（路径含空格时必须这样写）
       [a](b.md "title")     带标题
     实测确认过：只写第一种会漏掉后两种，于是一个合规的笔记被拒绝，
     而提示让人去加链接 —— 他明明已经加了。 */
  const linkPattern = /\]\(\s*(?:<([^>]+\.md)(?:#[^>]*)?>|([^)\s]+\.md)(?:#[^)\s]*)?)(?:\s+"[^"]*")?\s*\)/g;
  const links = [...text.matchAll(linkPattern)]
    .map((m) => (m[1] ?? m[2] ?? '').trim())
    .filter((href) => href !== '' && !/^[a-z]+:/i.test(href) && !href.startsWith('/'));
  if (links.length > 0) {
    return { ok: true, reason: `有 ${links.length} 个相对链接` };
  }

  /* ② 显式声明独立。
     正则里的 `\S` 已保证「冒号后至少有一个非空白字符」——
     所以 `Independent:` 或 `Independent:   ` 不会匹配，自然落到「未声明」。
     这里不再额外做 trim 检查：实测确认那是死代码（永远走不到），
     而死代码会让人误以为它在守着什么。故障注入时它没被执行到，
     正是「测试在测别的东西」的证据。 */
  const independent = /^Independent:[ \t]*(\S.*)$/m.exec(text);
  if (independent !== null) {
    return { ok: true, reason: `声明独立 —— ${independent[1].trim()}` };
  }

  return { ok: false, reason: '既没有指向既有笔记的相对链接，也没有 Independent: 声明' };
}

const argv = process.argv.slice(2);
const rangeFlag = argv.indexOf('--range');
const rangeValue = rangeFlag >= 0 ? argv[rangeFlag + 1] : undefined;
const envBase = process.env.NOTES_SUPERSESSION_BASE;
const range = rangeValue ?? envBase;

const repoRootResult = git(['rev-parse', '--show-toplevel']);
if (!repoRootResult.ok) {
  console.error('✖ 当前目录不是 git 仓库，无法做 supersession 检查。退出码 2。');
  process.exit(2);
}
const repoRoot = repoRootResult.out.trim();

const { noteDirs, error: configError } = loadNoteDirs(repoRoot);
if (configError !== undefined) {
  console.error('✖ 配置文件读不出来，本次检查无效。');
  console.error(`  ${configError}`);
  process.exit(2);
}

/**
 * 跑 `git diff` 并返回新增文件路径。
 *
 * 与 notes-coverage.mjs 用同一套防御性 flag —— 理由见那里的注释。
 * 最关键的是 `-z`：不带它时中文路径会被转义，导致笔记静默逃检。
 *
 * @param {string[]} args diff 的其余参数。
 * @returns {{ ok: boolean, files: string[] | undefined, err: string }} 路径列表。
 */
function diffAdded(args) {
  const result = git([
    'diff',
    '--no-ext-diff',
    '--no-textconv',
    '--no-renames',
    '--ignore-submodules=none',
    '--name-status',
    '-z',
    ...args,
    '--'
  ]);
  if (!result.ok) return { ok: false, files: undefined, err: result.err };
  return { ok: true, files: addedPathsZ(result.out), err: '' };
}

let added;
let label;
if (typeof range === 'string' && range !== '') {
  const spec = range.includes('..') ? range : `${range}..HEAD`;
  const result = diffAdded(['--diff-filter=A', spec]);
  if (!result.ok) {
    console.error('✖ 无法读取提交区间，本次检查无效。退出码 2。');
    console.error(`  ${result.err.trim()}`);
    process.exit(2);
  }
  added = result.files;
  label = spec;
} else {
  const result = diffAdded(['--cached', '--diff-filter=A']);
  if (!result.ok) {
    console.error('✖ 无法读取暂存区，本次检查无效。退出码 2。');
    console.error(`  ${result.err.trim()}`);
    process.exit(2);
  }
  added = result.files;
  label = '暂存区';
}

const newNotes = added.filter((path) => isNote(path, noteDirs));
const pending = newNotes.filter((path) => !isDraft(path));

if (pending.length === 0) {
  if (newNotes.length === 0) {
    console.log(`supersession 检查通过（${label}）：没有新增笔记。`);
  } else {
    console.log(
      `supersession 检查通过（${label}）：${newNotes.length} 篇新增笔记都在 proposed/rejected，`
      + '尚未成为已落地的决定，不要求挂靠。'
    );
  }
  process.exit(0);
}

const failures = [];
for (const path of pending) {
  const verdict = declaresRelation(repoRoot, path);
  if (!verdict.ok) failures.push({ path, reason: verdict.reason });
}

if (failures.length === 0) {
  console.log(`supersession 检查通过（${label}）：${pending.length} 篇新笔记都声明了与既有笔记的关系。`);
  process.exit(0);
}

console.error('✖ 有新增笔记没有声明它与既有笔记的关系。');
console.error('');
console.error(`  检查范围：${label}`);
for (const failure of failures) {
  console.error(`    ${failure.path}`);
  console.error(`        ${failure.reason}`);
}
console.error('');
console.error('写新笔记前要先查既有笔记树，判定是「完全取代 / 部分取代 / 无关」。');
console.error('（这条规则借鉴 deepseek-harness 的 .agents/notes/AGENTS.md：');
console.error('  Every new Agent Note triggers a supersession check.）');
console.error('');
console.error('三种做法，任选其一：');
console.error('');
console.error('  ① 部分取代 / 相关：在正文里用相对链接指向它');
console.error('     [../bug-fix/2026-01-01-old.md](../bug-fix/2026-01-01-old.md)');
console.error('');
console.error('  ② 完全取代：同样加链接，并在旧笔记里注明已被本篇取代');
console.error('');
console.error('  ③ 确实无关：在正文里加一行');
console.error('     Independent: <为什么它与现有决定无关>');
console.error('');
console.error('查既有笔记：');
console.error('  rg --hidden --glob "!.agents/notes/archived/**" "<机制名或关键词>" .agents/notes/');
process.exit(1);
