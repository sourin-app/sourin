#!/usr/bin/env node
/**
 * 覆盖门禁：**该写笔记的改动，必须同批带一篇笔记**。
 *
 * ## 为什么需要它（这是本仓库真实踩过的坑）
 *
 * 既有的 `notes:gate` 校验的是「**已经写了的**笔记格式对不对」——
 * 头块、状态、必备节、备选方案、相对链接。它**从不检查「该写而没写」**。
 * 于是出现了一个稳定复现的失效模式：
 *
 *   修 CI 时连续 5 次提交改了 `.github/workflows/verify.yml`，一次笔记都没写。
 *   而这恰恰是规范里明确要求记录的「改了流程与工具链」。
 *
 * 原因不是规范写错了 —— 规范连「对 AI 来说写在散文里的规矩等于没有规矩」
 * 都写进去了。真正的原因是：**判断「要不要写」这一步全靠模型自觉，
 * 而多轮对话里它一定会忘。** 规范自己承认这一点，却没有给出兜底。
 *
 * 所以这里把「要不要写」从语义判断降级成**机械可判定的路径规则**：
 * 只要改动命中受管路径，同一次提交里就必须有 `.agents/notes/` 的变更。
 *
 * ## 判定口径（刻意保守，宁少报不多报）
 *
 * 命中即要求笔记：
 *   - `lib/**`            插件运行时行为
 *   - `tools/**`          工具链与门禁
 *   - `.github/**`        CI 流程
 *   - `skills/agent-notes/**`   vendored 内容（正常由 sync 维护，手改必须解释）
 *
 * 明确**不要求**（否则门禁会被噪音淹没，最后被 --no-verify 绕过）：
 *   - `.agents/notes/**`  笔记本身
 *   - `CHANGELOG.md` / `README*.md` / `LICENSE`   文档
 *   - `package.json` / `upstream.json` / `tools/upstream-manifest.json`
 *     版本号、上游 ref、清单摘要 —— 这些是 `sync` / `bump-version` 的
 *     机械产物，写笔记反而是噪音（见规范里的「机械改动严禁立笔记」）
 *     ⚠️ 但 `tools/upstream-manifest.json` 在 `tools/**` 之下，
 *     所以下面用**显式豁免表**在路径命中之后再做减法。
 *   - `.probe/**` 等临时目录（通常已被 .gitignore 排除）
 *
 * ## 为什么做成「路径白名单」而不是「判断这次改动是否非平凡」
 *
 * 后者需要理解 diff 语义，做不到可靠。而路径白名单的**误报方向是安全的**：
 * 它只会多要求笔记，不会漏要求。真正不该写的改动可以走豁免标记（见下），
 * 而不是让门禁去猜。
 *
 * ## 用法
 *
 *   node <脚本路径>                      # 检查暂存区（提交钩子用）
 *   node <脚本路径> --range A..B         # 检查提交区间（CI 用）
 *   node <脚本路径> --config <file>      # 显式指定配置（默认读仓库根的
 *                                        #   .agents/notes-coverage.json）
 *
 * 环境变量：
 *   NOTES_COVERAGE_BASE   与 --range 等价（CI 里传 base sha 更方便）
 *
 * 退出码：0=通过（该写的都写了，或本来就不需要写）；1=有改动缺笔记；2=无法判定。
 * **2 也必须算失败** —— 「查不到」绝不能当成「没问题」。
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

/**
 * 默认的「受管路径」判定：**靠仓库自身的结构自动推断，不写死任何路径**。
 *
 * 为什么必须自动推断：这道门禁要装进各种各样的仓库 —— Node、Flutter+Rust、
 * 纯脚本仓、多语言 monorepo。把 `lib/`、`tools/` 写死只对某一个仓库成立，
 * 换到 `src/`、`app/`、`crates/`、`packages/` 就静默失效，而那正是
 * 「看起来有门禁、其实没在管」的最坏形态。
 *
 * 推断依据是**仓库里存在的文件**，不是猜测：
 *
 * 1. **源码目录**：顶层目录下若存在常见源码后缀的文件，视为源码目录
 *    （`lib/`、`src/`、`app/`、`crates/`、`packages/` 等都会被认出来）。
 * 2. **配置文件**：仓库根的清单/配置（`package.json`、`pubspec.yaml`、
 *    `Cargo.toml`、`go.mod`…）改动属于工具链变更。
 * 3. **流程文件**：`AGENTS.md` / `CLAUDE.md` / `.github/` 定义规则本身。
 * 4. **文档目录**：`docs/` 下的**计划与工作日志**不算决策笔记的替代品，
 *    所以默认**不**要求笔记（见 EXEMPT_PREFIXES），否则每天的计划更新
 *    都会被逼着立一篇，噪音立刻淹掉真信号。
 *
 * 这个默认值可以被配置文件覆盖（见 loadConfig），覆盖时**整体替换**而不是
 * 叠加 —— 半叠加最容易产生「我以为配了、其实没配」的错觉。
 */
const DEFAULT_SOURCE_DIR_HINTS = Object.freeze([
  'lib', 'src', 'app', 'apps', 'packages', 'crates', 'core',
  'test', 'tests', 'spec', 'scripts', 'tools', 'bin',
  'android', 'ios', 'macos', 'windows', 'linux', 'web'
]);

/**
 * 常见源码文件后缀。用来判断某个顶层目录里到底有没有代码。
 *
 * 刻意包含非 JS 生态：这道门禁要在 Flutter/Dart、Rust、Go、Kotlin 仓库里工作。
 */
const SOURCE_EXTENSIONS = Object.freeze([
  '.dart', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  '.rs', '.go', '.kt', '.java', '.swift', '.c', '.cc', '.cpp', '.h', '.hpp',
  '.cs', '.rb', '.php', '.py', '.scala', '.ex', '.exs', '.lua', '.sh'
]);

/**
 * 仓库根上的清单/配置文件：改了它们等于改工具链或依赖约束。
 *
 * **但不包含 `package.json`**：那是版本号与依赖清单，日常发布只改版本号，
 * 属于规范明令「严禁立笔记」的机械改动。把它无条件受管会让每次发版
 * 都被逼着写一篇注水笔记 —— 实测确认这是通用化第一版引入的回归。
 *
 * 判断依据是「这个文件一改，行为/架构/契约会变吗」：
 *   `pubspec.yaml` 的依赖约束、`Cargo.toml` 的 feature 会影响构建结果 → 受管
 *   `package.json` 的 `version` 字段 → 不受管
 * 若某个仓库确实希望 `package.json` 也受管，在 `.agents/notes-coverage.json`
 * 里用 `exemptFiles` 反过来控制并不方便，所以更好的做法是允许
 * `managedFiles` 配置（见 loadConfig）。
 */
const MANIFEST_FILES = Object.freeze([
  'pnpm-workspace.yaml', 'tsconfig.json',
  'pubspec.yaml',
  'Cargo.toml',
  'go.mod',
  'pyproject.toml', 'requirements.txt', 'setup.py',
  'build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts',
  'Podfile', 'Gemfile', 'composer.json', 'CMakeLists.txt'
]);

/**
 * 流程文件：定义「什么算改动」的规则本身。改它必须解释。
 *
 * `.agents/notes-scripts/` 在这里：那是门禁脚本本身，改它等于改规则。
 * 若漏了它，就会出现「改进门禁不用写笔记」的后门 —— 实测踩过
 * （第一版把整个 `.agents/` 豁免，门禁脚本自己的改动也不需要笔记）。
 */
const PROCESS_FILES = Object.freeze([
  'AGENTS.md',
  'CLAUDE.md',
  '.github/workflows/',
  '.agents/notes-scripts/',
  '.githooks/'
]);

/**
 * 判断一个路径是否命中「目录型」清单项。
 *
 * 清单项统一写成带尾斜杠的形式，这里同时容忍写成不带斜杠的历史写法 ——
 * 实测踩过：`.githooks` 写成不带斜杠时，`endsWith('/')` 判断直接跳过它，
 * 于是那个目录静默不受管。
 *
 * @param {string} path 仓库相对路径。
 * @param {readonly string[]} entries 清单项。
 * @returns {boolean} 是否命中。
 */
function hitDirEntry(path, entries) {
  return entries.some((entry) => path.startsWith(entry.endsWith('/') ? entry : `${entry}/`));
}

/**
 * 明确**不要求**笔记的路径前缀。
 *
 * `docs/` 是主要一条：本类仓库习惯把计划、工作日志、排查记录写在
 * `docs/notes/` 下，那是**过程**不是**决策**。若把 docs 也纳入受管，
 * 每天的计划更新都会被逼着立一篇决策笔记，几天之内整个笔记树就被注水，
 * 人开始用 `--no-verify`，门禁等于废掉。
 *
 * 这条判断有实测依据：在某个 Flutter 仓库统计最近 30 次提交，
 * 只有 2 次带笔记，但其中大部分是 `docs(round-66): ...` 改计划文件 ——
 * 那些本来就不该立决策笔记。真正漏的是改了 `lib/` 却没记的那几次。
 *
 * **注意 `.agents/` 不在这里。** 第一版把整个 `.agents/` 豁免，结果
 * 门禁脚本自己（`.agents/notes-scripts/notes-coverage.mjs`）改动也不要求
 * 笔记 —— 那是给「改门禁不写笔记」留后门，正是本门禁要堵的洞。
 * 现在只精确豁免**笔记目录本身**（见 noteDirs），`.agents/` 下其它内容
 * 照常按源码/工具链判定。
 */
const EXEMPT_PREFIXES = Object.freeze([
  'docs/',
  '.probe/',
  'node_modules/',
  'vendor/',
  'third_party/'
]);

/**
 * 受管路径内的豁免项（精确匹配）—— 各仓库可通过配置追加。
 *
 * 只豁免**机械产物**：例如某个同步工具写出来的哈希清单，
 * 为它写笔记是纯噪音。
 *
 * 注意这里**只放生成物，不放源码** —— 我第一版把 `tools/sync-upstream.mjs`
 * 误放进来，等于给「改门禁不写笔记」留了后门，正是本门禁要堵的那个洞。
 */
const DEFAULT_EXEMPT_FILES = Object.freeze([
  'package-lock.json',
  'pnpm-lock.yaml',
  'yarn.lock',
  'pubspec.lock'
]);

/**
 * 允许「这次确实不需要笔记」的显式标记。
 *
 * 提交信息里单独一行 `Note-Skip: <理由>` 即可放行。要求理由非空，
 * 因为「写了理由」这个动作本身就会让人再想一遍 —— 空理由直接拒绝。
 *
 * 为什么保留这个口子：路径白名单必然有误报（比如改个错别字、
 * 或纯粹调整注释）。没有合法出口的门禁只会被非法出口（--no-verify）绕过，
 * 那样连检查都跑不起来了。
 */
const SKIP_MARKER = /^Note-Skip:\s*(\S.*)$/m;

/**
 * git 输出的上限。
 *
 * `spawnSync` 默认 1MB，大仓库 `git ls-files` 会超。取值与
 * deepseek-harness 的 change-scope.ts 一致。
 */
const MAX_GIT_OUTPUT = 64 * 1024 * 1024;

/**
 * 跑 git 并返回 stdout。
 *
 * cwd 取**当前工作目录**而不是脚本所在目录：门禁要能对任意仓库生效
 * （测试就是在临时仓库里跑它），写死 PACKAGE_ROOT 会让它永远只看本仓库，
 * 换到别的项目就静默失效 —— 那是假绿的另一种形态。
 *
 * `maxBuffer` 显式放大到 64MB：`spawnSync` 默认 1MB，仓库大时 `git ls-files`
 * 会 ENOBUFS。实测：超限时 `status` 为 `null`，所以不会假绿（会走失败分支），
 * 但会**误报「无法判定」**，让门禁在大仓库上不可用。
 * 这个值取自 deepseek-harness 的 change-scope.ts。
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
 * 跑 `git diff` 并返回路径列表。
 *
 * ## 为什么带这一串 flag（全部来自 deepseek-harness 的 change-scope.ts）
 *
 * 我最初判定它们「不必要」，理由是「我没能构造出受影响的场景」。
 * 那是**错误的判据** —— 防御性 flag 的价值恰恰在于防那些罕见的、
 * 有人特意配置过的场景。逐条实测后全部推翻：
 *
 * - `-z`：**实测真缺陷**。不带它时 git 会把非 ASCII 路径转义成
 *   `"lib/\344\270\255..."` 并加引号，`startsWith('lib/')` 直接失败 ⇒
 *   中文路径的源码改动**静默放行**。这条是实际会踩到的。
 * - `--no-ext-diff` / `--no-textconv`：防 `.gitattributes` 里配了外部
 *   diff 驱动或 textconv，把文件内容换掉影响判定。
 * - `--no-renames`：改名检测受 `diff.renameLimit` 影响，仓库大时行为不确定。
 *   钉住之后「改名」稳定表现为「删旧 + 增新」，判定可复现。
 * - `--ignore-submodules=none`：防本地 `submodule.<name>.ignore = all`
 *   让 submodule 变更从列表里消失。
 * - 结尾的 `--`：防参数被当成路径。
 *
 * @param {string[]} args diff 的其余参数（如 --cached、--diff-filter）。
 * @returns {{ ok: boolean, files: string[] | undefined, err: string }} 路径列表。
 */
function diffPaths(args) {
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
  return { ok: true, files: statusLinesZ(result.out), err: '' };
}

/**
 * 取本次要检查的变更文件列表。
 *
 * 两种模式返回的形状不同，因为它们的正确语义本就不同：
 *   - 暂存区（本地钩子）：一次提交一批，合并看是**对的**；
 *   - 区间（CI）：可能含多次提交，必须**逐个提交**看。
 *     合并看会漏：区间里只要有一次带了笔记，其余改代码的提交全被掩护过去。
 *     实测确认：`base..HEAD` 含「带笔记的 probe1」+「改 lib 无笔记的 probe2」
 *     被判通过 —— 而那正是「一次 push 多个提交」的常见形态。
 *
 * @param {string[]} argv 命令行参数。
 * @returns {{ mode: 'staged'|'range', label: string, files?: string[],
 *             commits?: {sha: string, subject: string}[],
 *             reason?: string }} 检查目标。
 */
function collectTargets(argv) {
  const rangeFlag = argv.indexOf('--range');
  const rangeValue = rangeFlag >= 0 ? argv[rangeFlag + 1] : undefined;
  const envBase = process.env.NOTES_COVERAGE_BASE;

  const range = rangeValue ?? envBase;
  if (typeof range === 'string' && range !== '') {
    /* 允许 `--range <sha>`：自动补成 <sha>..HEAD。 */
    const spec = range.includes('..') ? range : `${range}..HEAD`;
    const listed = git(['rev-list', '--reverse', spec]);
    if (!listed.ok) {
      return { mode: 'range', label: spec, reason: `git rev-list 失败: ${listed.err.trim()}` };
    }
    const commits = splitLines(listed.out).map((sha) => ({
      sha,
      subject: git(['log', '-1', '--format=%s', sha]).out.trim()
    }));
    return { mode: 'range', label: spec, commits };
  }

  /* 本地：默认看暂存区（commit-msg 钩子的语义）。
     过滤删除（D）：删一篇旧笔记配合任意受管改动就能过门禁 —— 实测确认是后门。 */
  const result = diffPaths(['--cached', '--diff-filter=ACMR']);
  if (!result.ok) {
    return { mode: 'staged', label: '暂存区', reason: `git diff --cached 失败: ${result.err.trim()}` };
  }
  return { mode: 'staged', label: '暂存区', files: result.files };
}

/**
 * 取某个提交自己改动的文件（相对它的父提交）。
 *
 * 用 `<sha>^!` 而不是 `<sha>..<sha>`：后者是空集。
 * 首个提交没有父提交，`^!` 会自然退化成「该提交本身引入的全部文件」。
 *
 * @param {string} sha 提交 sha。
 * @returns {{ files: string[] | undefined, reason?: string }} 文件列表。
 */
const filesCache = new Map();

function filesOfCommit(sha) {
  /* 同一次运行里同一个提交会被问两次（认领扫描 + 逐提交判定），缓存住。 */
  const cached = filesCache.get(sha);
  if (cached !== undefined) return cached;
  /* 过滤删除（D）：删除一篇笔记不能算「带了笔记」。 */
  const result = diffPaths(['--diff-filter=ACMR', `${sha}^!`]);
  const verdict = result.ok
    ? { files: result.files }
    : { files: undefined, reason: `git diff ${sha}^! 失败: ${result.err.trim()}` };
  filesCache.set(sha, verdict);
  return verdict;
}

/**
 * 找本门禁的出生提交：**最早一次新增本脚本**的那个提交。
 *
 * 为什么要知道自己的生日：这道门禁 2026-10-18 才接进 CI。它出生之前，
 * main 上的历史从来没被要求过笔记 —— 拿它回头审判史前史，唯一结果是
 * 永远红（实测：`--range bdf64357~40..bdf64357` 报 216 个提交缺笔记），
 * 然后被人用 `--no-verify` 绕过，门禁就死了。
 *
 * ⚠️ 认不出重命名：本文件若改名，这里会算出更晚的出生点，从而放走一段
 * 本该受管的历史。所以调用方必须把出生点 sha 与日期打印出来。
 *
 * @returns {{ sha: string | undefined, date?: string }} 出生提交。
 */
function gateBirthCommit() {
  const listed = git([
    'log', '--diff-filter=A', '--format=%H %cs', '--',
    '.agents/notes-scripts/notes-coverage.mjs'
  ]);
  if (!listed.ok) return { sha: undefined };
  const lines = splitLines(listed.out);
  if (lines.length === 0) return { sha: undefined };
  // `git log` 新的在前，最老的那条在最后。
  const oldest = lines[lines.length - 1].split(' ');
  return { sha: oldest[0], date: oldest[1] ?? '?' };
}

/**
 * `sha` 是否「不晚于」`ancestor`。
 *
 * `git merge-base --is-ancestor A B` 在 A 是 B 的祖先**或两者相同**时
 * 退出码为 0 —— 正好是这里要的语义。
 *
 * @param {string} sha 待判定的提交。
 * @param {string} ancestor 参照提交。
 * @returns {boolean} 不晚于则 true。
 */
function isAncestorOrSelf(sha, ancestor) {
  if (sha === ancestor) return true;
  return git(['merge-base', '--is-ancestor', sha, ancestor]).ok;
}

/**
 * 从笔记正文里解析 `covers:` 声明。
 *
 * 一行一个声明，可写多个 sha，逗号或空白分隔；只接受 7~40 位十六进制，
 * 其他写法一律忽略（宁可漏认领，也不要让一串自由文本变成万能后门）。
 *
 * @param {string} text 笔记全文。
 * @returns {string[]} 被认领的 sha 前缀。
 */
function parseCovers(text) {
  const out = [];
  const pattern = /^covers:\s*(.+)$/gim;
  let match = pattern.exec(text);
  while (match !== null) {
    for (const raw of match[1].split(/[,\s]+/)) {
      const token = raw.trim().toLowerCase();
      if (/^[0-9a-f]{7,40}$/.test(token)) out.push(token);
    }
    match = pattern.exec(text);
  }
  return out;
}

/**
 * 收集「后补笔记认领了哪些历史提交」。
 *
 * `explainFailure` 里一直写着「补法：… 可另起一个「补笔记」提交」，但在
 * 逐个提交判定之下那句承诺是**假的** —— 后补的笔记落在新提交里，认领不了
 * 任何更早的提交。这里把承诺补成真的：笔记正文写 `covers: <sha>` 即可。
 *
 * 防滥用三条：① 只有**区间内**出现的笔记才算；② 认领的 sha 必须能在本区间
 * 里找到（区间外的一律无效）；③ 每一次认领都打印出来。
 *
 * @param {{sha: string}[]} commits 区间内的提交（按时间正序）。
 * @returns {Map<string, string>} 提交 sha → 认领它的笔记路径。
 */
function collectCoveredShas(commits) {
  const inRange = commits.map((commit) => commit.sha);
  const claims = new Map();
  for (const commit of commits) {
    const got = filesOfCommit(commit.sha);
    if (got.files === undefined) continue;
    for (const path of got.files) {
      if (!path.startsWith(notePrefix) || !path.endsWith('.md')) continue;
      const shown = git(['show', `${commit.sha}:${path}`]);
      if (!shown.ok) continue;
      for (const token of parseCovers(shown.out)) {
        for (const sha of inRange) {
          if (sha.startsWith(token) && !claims.has(sha)) claims.set(sha, path);
        }
      }
    }
  }
  return claims;
}

/**
 * 按行切分并去掉空项。
 *
 * @param {string} text 原始输出。
 * @returns {string[]} 路径列表。
 */
function splitLines(text) {
  return text.split('\n').map((line) => line.trim()).filter((line) => line !== '');
}

/**
 * 解析 `git diff --name-status -z` 的 NUL 分隔输出，只返回文件路径。
 *
 * ## 为什么必须用 -z
 *
 * 不带 `-z` 时 git 会对「不寻常」的路径做 C 风格转义并加引号：
 *
 * ```text
 * A  "lib/\344\270\255\346\226\207.js"     ← 中文路径被转义
 * ```
 *
 * 于是 `startsWith('lib/')` 失败 ⇒ **中文路径的源码改动被静默放行**。
 * 这是实测发现的真缺陷（不是理论风险）：一个叫 `lib/中文.js` 的文件
 * 改了代码，门禁报「改动未命中受管路径」并通过。
 *
 * `-z` 用 NUL 分隔记录，路径原样输出，不做任何转义。
 * 记录格式为：`状态\0路径\0`（改名是 `R100\0旧路径\0新路径\0`）。
 *
 * @param {string} text NUL 分隔的原始输出。
 * @returns {string[]} 路径列表。
 */
function statusLinesZ(text) {
  const records = text.split('\u0000').filter((entry) => entry !== '');
  const out = [];
  let index = 0;
  while (index < records.length) {
    const status = records[index];
    index += 1;
    if (status.startsWith('R') || status.startsWith('C')) {
      /* 改名/复制有两条路径：旧路径跳过，取新路径（它才是当前存在的）。 */
      index += 1;
      if (index < records.length) {
        out.push(records[index]);
        index += 1;
      }
      continue;
    }
    if (index < records.length) {
      out.push(records[index]);
      index += 1;
    }
  }
  return out;
}

/**
 * 判断某个路径是否要求配笔记。
 *
 * 判定顺序（先否后肯，避免豁免表被前面的规则绕过）：
 *   1. 笔记目录自身（写笔记不需要再写笔记）→ 不要求
 *   2. 显式豁免的精确文件（生成物、锁文件）→ 不要求
 *   3. 豁免前缀（`docs/`、依赖目录等）→ 不要求
 *   4. 流程文件（`AGENTS.md`、`.github/workflows`…）→ 要求
 *   5. 仓库根清单（`pubspec.yaml`、`Cargo.toml`…）→ 要求
 *   6. 检测出的源码目录下的文件 → 要求
 *   7. 其余 → 不要求
 *
 * @param {string} path 仓库相对路径。
 * @param {{exemptFiles: string[], sourceDirs: string[], noteDirs: string[]}} rules 生效规则。
 * @returns {boolean} 是否受管。
 */
function isManaged(path, rules) {
  /* 笔记目录自身永远不要求笔记 —— 否则「补一篇笔记」这件事本身又需要一篇笔记。 */
  if (rules.noteDirs.some((dir) => path.startsWith(`${dir.replace(/\/$/, '')}/`))) return false;
  if (rules.exemptFiles.includes(path)) return false;
  if (EXEMPT_PREFIXES.some((prefix) => path.startsWith(prefix))) return false;
  if (rules.managedFiles.includes(path)) return true;
  if (PROCESS_FILES.includes(path)) return true;
  if (hitDirEntry(path, PROCESS_FILES)) return true;
  if (MANIFEST_FILES.includes(path)) return true;
  return rules.sourceDirs.some((dir) => path.startsWith(`${dir}/`));
}

/**
 * 推断仓库里哪些顶层目录是「源码目录」。
 *
 * 判据是**目录里真有代码**，而不是目录名像不像。做法：对 `git ls-files`
 * 的输出按顶层目录分组，看是否存在常见源码后缀的文件。
 *
 * 为什么不用「目录名在白名单里」这种简单判断：那要求门禁知道每个仓库的
 * 目录习惯（Flutter 用 `lib/`、Rust 用 `crates/`、monorepo 用 `packages/`），
 * 等于把仓库知识写死进工具。用「有没有代码」判定是语言无关的。
 *
 * @param {string[]} trackedFiles 仓库里被 git 跟踪的文件（相对路径）。
 * @returns {string[]} 源码目录名列表（不含尾斜杠）。
 */
function detectSourceDirs(trackedFiles) {
  const hit = new Set();
  for (const path of trackedFiles) {
    const slash = path.indexOf('/');
    if (slash <= 0) continue;
    const top = path.slice(0, slash);
    if (hit.has(top)) continue;
    /* 只认「顶层目录」本身，不再往下递归：子目录里的代码归属顶层。 */
    const dot = path.lastIndexOf('.');
    if (dot < 0) continue;
    const ext = path.slice(dot).toLowerCase();
    if (SOURCE_EXTENSIONS.includes(ext)) hit.add(top);
  }
  return [...hit].sort();
}

/**
 * 读取可选配置。
 *
 * 优先级：`--config <file>` > `<仓库根>/.agents/notes-coverage.json` > 默认。
 *
 * 配置里能覆盖的三项（都是**整体替换**，不是追加）：
 *   sourceDirs   源码目录（不写则自动检测）
 *   exemptFiles  额外豁免的精确文件
 *   noteDirs     笔记所在目录（默认 `.agents/notes`）
 *
 * 为什么整体替换：半叠加最容易产生「我以为配了、其实没配」的错觉，
 * 而门禁类工具最怕的就是这种模糊状态。
 *
 * 配置读不出来时**明确失败**（退出码 2），不静默退回默认 ——
 * 那会让人以为配置生效了而其实没有。
 *
 * @param {string} repoRoot 仓库根。
 * @param {string[]} argv 命令行参数。
 * @returns {{config: object|undefined, error?: string}} 配置或错误。
 */
function loadConfig(repoRoot, argv) {
  const flag = argv.indexOf('--config');
  const explicit = flag >= 0 ? argv[flag + 1] : undefined;
  const implicit = join(repoRoot, '.agents', 'notes-coverage.json');
  const file = typeof explicit === 'string' && explicit !== ''
    ? resolve(repoRoot, explicit)
    : (existsSync(implicit) ? implicit : undefined);
  if (file === undefined) return { config: {} };

  let raw;
  try {
    raw = JSON.parse(readFileSync(file, 'utf8'));
  } catch (error) {
    return { config: undefined, error: `读取配置 ${file} 失败：${error.message}` };
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return { config: undefined, error: `配置 ${file} 必须是一个 JSON 对象。` };
  }
  const config = { path: file };
  for (const key of ['sourceDirs', 'exemptFiles', 'managedFiles', 'noteDirs']) {
    if (raw[key] === undefined) continue;
    if (!Array.isArray(raw[key]) || raw[key].some((v) => typeof v !== 'string')) {
      return { config: undefined, error: `配置项 ${key} 必须是字符串数组。` };
    }
    config[key] = raw[key];
  }
  return { config };
}

/**
 * 找出「顶层目录」里的未归类项。
 *
 * 自动检测能覆盖大多数情况，但它仍可能漏：例如一个**新出现的**顶层目录，
 * 里面暂时只有一个 README（没有源码后缀），于是没被认成源码目录，
 * 之后往里加代码就静默不受管。
 *
 * 所以额外做一次显式报告：从本次改动路径里抽顶层目录，凡既不是已检测出的
 * 源码目录、也不在豁免前缀里的，打一条警告。**不失败**（避免误报淹没真问题），
 * 但必须出现在输出里 —— 至少不再无声无息。
 *
 * @param {string[]} paths 本次改动的仓库相对路径。
 * @param {{sourceDirs: string[]}} rules 生效规则。
 * @returns {string[]} 未归类的顶层目录名（去重、已排序）。
 */
function unclassifiedTopDirs(paths, rules) {
  const out = new Set();
  for (const path of paths) {
    const slash = path.indexOf('/');
    /* 只看目录下的文件；顶层散文件由 PROCESS_FILES / MANIFEST_FILES 管。 */
    if (slash <= 0) continue;
    const top = path.slice(0, slash);
    if (rules.sourceDirs.includes(top)) continue;
    /* 已经由流程文件/配置显式受管的目录，不算「未归类」。
       注意清单项可能是**嵌套**的（`.github/workflows/`、`.agents/notes-scripts/`），
       而这里的 `top` 只是顶层段（`.github`、`.agents`）。只做前缀匹配会漏 ——
       实测踩过两次：先 `.agents/notes`，再 `.github/workflows`，
       都出现「明明受管却被报未归类」的噪音误报。
       所以两段都比：整条命中或顶层段命中都算已归类。 */
    if (PROCESS_FILES.some((entry) => {
      const norm = entry.endsWith('/') ? entry : `${entry}/`;
      return norm === `${top}/` || norm.startsWith(`${top}/`);
    })) continue;
    if (rules.managedFiles.some((entry) => entry === `${top}/` || entry.startsWith(`${top}/`))) continue;
    if (EXEMPT_PREFIXES.some((prefix) => prefix === `${top}/`)) continue;
    /* 笔记目录可能是嵌套的（默认 `.agents/notes`），要比**顶层段**而非全路径：
       第一版直接比整条路径，于是 `.agents/notes` 匹配不上 `.agents`，
       写笔记这件事自己被报成「未归类目录」。 */
    if (rules.noteDirs.some((dir) => dir.replace(/\/$/, '').split('/')[0] === top)) continue;
    out.add(top);
  }
  return [...out].sort();
}

/**
 * 从提交信息里找放行标记。
 *
 * @returns {string | undefined} 理由；没有标记则为 undefined。
 */
function skipReason() {
  /* 只接受两个来源：环境变量，或 commit-msg 传进来的**本次**提交信息。
     绝不回退去读 `git log -1`（上一次提交）—— 实测确认那是永久后门：
     上一条提交写过 `Note-Skip:`，紧接着毫不相干的改动就被静默放行。
     那比没有门禁更危险，因为看起来还在管。 */
  const fromEnv = process.env.NOTES_COVERAGE_SKIP;
  if (typeof fromEnv === 'string' && fromEnv.trim() !== '') return fromEnv.trim();
  return SKIP_MARKER.exec(pendingCommitMessage() ?? '')?.[1];
}

/**
 * 读本次正在创建的提交信息。
 *
 * 由 `commit-msg` 钩子把 `$1`（COMMIT_EDITMSG 路径）通过参数传进来。
 * `pre-commit` 阶段没有这个东西 —— 那时本次提交信息还没生成，
 * 所以 `Note-Skip` 天然要由 `commit-msg` 承担（只用一个钩子会漏）。
 *
 * @returns {string | undefined} 提交信息正文；不是从 commit-msg 调用则为 undefined。
 */
function pendingCommitMessage() {
  const flag = process.argv.indexOf('--message-file');
  const file = flag >= 0 ? process.argv[flag + 1] : undefined;
  if (typeof file !== 'string' || file === '') return undefined;
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
}

const argvAll = process.argv.slice(2);
const target = collectTargets(argvAll);

if (target.mode === 'staged' && target.files === undefined) {
  console.error('✖ 无法判定本次改动是否配了笔记。');
  console.error(`  ${target.reason ?? '未知原因'}`);
  console.error('  这不是「已合规」—— 本次检查无效，退出码 2。');
  process.exit(2);
}
if (target.mode === 'range' && target.commits === undefined) {
  console.error('✖ 无法读取提交区间，本次检查无效。');
  console.error(`  ${target.reason ?? '未知原因'}`);
  console.error('  这不是「已合规」—— 退出码 2。');
  process.exit(2);
}

/* 仓库根：git 说了算，不靠脚本自己在哪。这样同一份脚本能装进任何仓库。 */
const repoRootResult = git(['rev-parse', '--show-toplevel']);
const repoRoot = repoRootResult.ok ? repoRootResult.out.trim() : process.cwd();

const { config, error: configError } = loadConfig(repoRoot, argvAll);
if (config === undefined) {
  console.error('✖ 配置文件读不出来，本次检查无效。');
  console.error(`  ${configError}`);
  console.error('  不以默认值继续 —— 那会让人以为配置生效了而其实没有。退出码 2。');
  process.exit(2);
}

/* 生效规则：配置整体替换默认值；源码目录不配则自动检测。 */
let detected = [];
if (config.sourceDirs === undefined) {
  const listed = git(['ls-files']);
  if (!listed.ok) {
    console.error('✖ 读不到仓库文件列表（git ls-files 失败），无法推断源码目录。');
    console.error('  这不是「已合规」—— 本次检查无效，退出码 2。');
    process.exit(2);
  }
  detected = detectSourceDirs(splitLines(listed.out));
}
const noteDirs = config.noteDirs ?? ['.agents/notes'];
const rules = {
  sourceDirs: config.sourceDirs ?? detected,
  exemptFiles: [...DEFAULT_EXEMPT_FILES, ...(config.exemptFiles ?? [])],
  managedFiles: config.managedFiles ?? [],
  noteDirs
};
const noteDir = noteDirs[0] ?? '.agents/notes';
const notePrefix = `${noteDir.replace(/\/$/, '')}/`;

/**
 * 判断一批文件是否「有受管改动但没带笔记」。
 *
 * @param {string[]} files 这批改动的文件。
 * @returns {{ managed: string[], hasNote: boolean, ok: boolean }} 判定结果。
 */
function evaluate(files) {
  const managed = files.filter((path) => isManaged(path, rules));
  const hasNote = files.some((path) => path.startsWith(notePrefix) && path.endsWith('.md'));
  return { managed, hasNote, ok: managed.length === 0 || hasNote };
}

/**
 * 报告未归类的顶层目录（不失败，只提示）。
 *
 * 自动检测能覆盖大多数情况，但仍可能漏：新出现的顶层目录若暂时没有源码
 * 文件，就不算源码目录，之后往里加代码会静默不受管。这里让它露一面。
 *
 * @param {string[]} files 要检查的文件。
 */
function warnUnclassified(files) {
  const stray = unclassifiedTopDirs(files, rules);
  if (stray.length === 0) return;
  console.error(`⚠ 以下顶层目录没被识别为受管，本次未检查：${stray.join('、')}`);
  console.error('  若它们属于源码/工具链，在仓库根加 .agents/notes-coverage.json：');
  console.error('    { "sourceDirs": ["你的目录", ...] }');
  console.error('  否则那个目录会一直被静默放行。');
}

/**
 * 打印「为什么不行 / 怎么修」。被两个失败分支共用。
 *
 * @param {string} scope 检查范围说明。
 * @param {string[]} managed 受管文件。
 */
function explainFailure(scope, managed) {
  console.error('✖ 有受管路径的改动，但本次没有带决策笔记。');
  console.error('');
  console.error(`  检查范围：${scope}`);
  for (const path of managed) console.error(`    ${path}`);
  console.error('');
  console.error('这些路径一改，行为/工具链/流程就变了，按规范属于「非平凡改动」。');
  console.error('请在 .agents/notes/ 下补一篇（推荐用 agent-notes 技能，含 Problem /');
  console.error('Decision / Alternatives considered / Consequences 四节）：');
  console.error('');
  console.error('  .agents/notes/{proposed|implemented|rejected|archived}/');
  console.error('    {feature|bug-fix|simplification|architecture|process|testing}/yyyy-mm-dd-主题.md');
  console.error('');
  console.error('如果这次确实只是机械改动（错别字、纯注释、生成物），在提交信息里加一行：');
  console.error('');
  console.error('  Note-Skip: <一句话理由>');
  console.error('');
  console.error('理由必须非空 —— 写理由这个动作本身就是要你再想一遍。');
}

/* ── 区间模式：**逐个提交**检查 ───────────────────────────────────────
   实测确认的后门：合并看区间时，只要区间里有**一次**带了笔记，
   其余改代码却漏记的提交全被掩护过去。那正是「一次 push 多个提交」的
   常见形态 —— 也是最需要门禁盯住的形态。所以这里按提交逐个判定。 */
if (target.mode === 'range') {
  const failures = [];
  const strayFiles = [];

  /* ── 自限出生点：门禁不管它出生之前的提交 ──────────────────────────
     它出生（2026-10-18，e0ab611 接进 CI）之前的提交从来没被要求过笔记。
     拿它回头审判史前史，结果只能是永远红 ⇒ 被人用 --no-verify 绕过 ⇒
     门禁变成摆设。所以区间起点一旦早于出生点，就收窄到出生点之后，并且
     **把收窄动作打印出来** —— 那不是「全区间通过」，是「前 n 个不归它管」。 */
  const birth = gateBirthCommit();
  if (birth.sha === undefined) {
    console.error('⚠ 认不出本门禁的出生提交（读不到新增记录）⇒ 不收窄，按原区间全量检查。');
  } else {
    let preBirth = 0;
    while (preBirth < target.commits.length
      && isAncestorOrSelf(target.commits[preBirth].sha, birth.sha)) {
      preBirth += 1;
    }
    if (preBirth > 0) {
      console.error(`ℹ 区间起点早于门禁出生点（${birth.sha.slice(0, 7)} ${birth.date}）`
        + ` ⇒ 前 ${preBirth} 个提交不归本门禁管，只检查其后的`
        + ` ${target.commits.length - preBirth} 个。`);
      target.commits = target.commits.slice(preBirth);
    }
  }

  /* ── covers：后补的笔记认领它之前的提交 ─────────────────────────── */
  const coveredBy = collectCoveredShas(target.commits);

  for (const commit of target.commits) {
    const got = filesOfCommit(commit.sha);
    if (got.files === undefined) {
      console.error('✖ 无法读取提交内容，本次检查无效。');
      console.error(`  ${got.reason}`);
      process.exit(2);
    }
    strayFiles.push(...got.files);

    const verdict = evaluate(got.files);
    if (verdict.ok) continue;

    /* 每个提交可以用自己的 Note-Skip 放行 —— 但只影响它自己。 */
    const ownSkip = SKIP_MARKER.exec(git(['log', '-1', '--format=%B', commit.sha]).out)?.[1];
    if (typeof ownSkip === 'string' && ownSkip.trim() !== '') {
      console.log(`  ✔ ${commit.sha.slice(0, 7)} 已用 Note-Skip 放行 —— ${ownSkip.trim()}`);
      continue;
    }
    failures.push({ sha: commit.sha, subject: commit.subject, managed: verdict.managed });
  }

  warnUnclassified(strayFiles);

  if (failures.length === 0) {
    const stray = unclassifiedTopDirs(strayFiles, rules);
    void stray;
    console.log(
      `笔记覆盖门禁通过（${target.label}）：检查了 ${target.commits.length} 个提交，`
      + '每次受管改动都同批带了笔记。'
    );
    process.exit(0);
  }

  console.error(`✖ 有 ${failures.length} 个提交改了受管路径却没带决策笔记。`);
  console.error('  逐个提交检查：一个提交带的笔记**不能**替另一个提交顶账。');
  console.error('');
  for (const failure of failures) {
    console.error(`  ${failure.sha.slice(0, 7)}  ${failure.subject}`);
    for (const path of failure.managed) console.error(`      ${path}`);
    console.error('');
  }
  console.error('补法：为每个提交补一篇笔记（可另起一个「补笔记」提交，');
  console.error('      或把笔记 amend 进对应提交），或用 Note-Skip 说明为何不必。');
  process.exit(1);
}

/* ── 暂存区模式（本地 commit-msg 钩子）：合并看这一批 ───────────────── */
const files = target.files;
const verdict = evaluate(files);
const label = target.label;

if (verdict.ok) {
  warnUnclassified(files);
  if (verdict.managed.length === 0) {
    console.log(`笔记覆盖门禁通过（${label}）：改动未命中受管路径，无需笔记。`);
  } else {
    console.log(`笔记覆盖门禁通过（${label}）：命中 ${verdict.managed.length} 个受管路径，且同批带了笔记。`);
  }
  process.exit(0);
}

/* 走到这里：有受管改动但没有笔记。看有没有显式放行。
   skipReason() 内部已只认「环境变量」与「本次提交信息」，不再回退到
   上一次提交 —— 那条回退曾导致写一次 Note-Skip 就永久开门。 */
const reasonText = skipReason();

if (typeof reasonText === 'string' && reasonText.trim() !== '') {
  console.log(`笔记覆盖门禁通过（${label}）：已用 Note-Skip 放行 —— ${reasonText.trim()}`);
  process.exit(0);
}

explainFailure(label, verdict.managed);
warnUnclassified(files);
process.exit(1);
