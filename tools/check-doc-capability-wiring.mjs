#!/usr/bin/env node
/**
 * 软报告：能力位文档的「用户看到什么」是否真的接到了代码？
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 这个脚本解决什么问题
 * ══════════════════════════════════════════════════════════════════════════
 *
 * 2026-10-20 发现：`capability-bits.md` 说 `danmaku: false` 时「不显示弹幕入口」，
 * 但实际代码里这个位**只影响设置页的一枚标签** —— 弹幕面板根本不读它。
 *
 * 那是**靠人读文档 + 人读代码**对出来的。同类矛盾还有多少？没人知道。
 *
 * ⇒ 本脚本把「某个能力位在 UI 层有没有读取点」这件事**机械化**。
 *
 * ══════════════════════════════════════════════════════════════════════════
 * ★ 判据设计：为什么这样才是"作用域无关"的
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ```text
 * ❌ 不要写「孤儿位数量必须 ≥ 1」
 *    —— 若某天所有位都接好了，这条会**永远红**；
 *       若某天扫描器坏了，这条会**永远绿**（0 个孤儿 = 通过）。
 *    ⇒ 同一数字判据，在不同作用域下既是真理又是毒药。
 *
 * ❌ 不要写「孤儿位数量必须 == 0」
 *    —— 孤儿位可能是**合法设计**（如 danmaku 只影响一枚标签，
 *       那是可接受的，不是缺陷）。
 *    ⇒ 会逼人去"给每个位加个读取点"，那是**为门禁写代码**。
 *
 * ✅ 正确判据（本脚本采用）：
 *      ① **每个文档里出现的能力位，都必须被分类**（接到线 / 孤儿 / 未映射）
 *      ② **扫描器必须证明自己工作过**（至少解析到 1 个能力位、至少扫到 1 个 dart 文件）
 *      ③ 孤儿位**如实列出**，但不判红 —— 让人自己判断它是设计还是缺陷
 *
 *    ⇒ ①② 是**硬判据**（扫描器坏了要红），③ 是**软报告**（只打印）。
 *       这样无论文档里有几个位，脚本都成立。
 * ```
 *
 * ══════════════════════════════════════════════════════════════════════════
 * 用法
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ```bash
 * # 默认：软报告，退出码 0（除非扫描器自身坏了）
 * node tools/check-doc-capability-wiring.mjs
 *
 * # 指定文档（可多个，逗号分隔）
 * node tools/check-doc-capability-wiring.mjs --docs ../sourin-plugins/docs/capability-bits.md
 *
 * # 严格模式：孤儿位也判红（默认关，因为孤儿可能是合法设计）
 * node tools/check-doc-capability-wiring.mjs --strict
 * ```
 *
 * 退出码：
 *   0 = 扫描器正常（孤儿位只报告，不判失败）
 *   1 = **扫描器自身出问题**（没解析到能力位 / 没扫到 dart 文件 / --strict 下有孤儿）
 *   2 = 参数/环境错误
 */

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import { join, resolve, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = resolve(HERE, '..')

/* ══════════════════════════════════════════════════════════════════════
 *  ★ 文档名 → 代码名 的映射表
 *
 *  # 为什么必须有这张表（而不是靠"名字相同"去猜）
 *  ```text
 *  文档写的是 **camelCase 的能力位名**（`danmakuSend`），
 *  而代码里的读取形态有**多种**：
 *    · `caps.danmakuSend`          —— 直接字段
 *    · `c.danmakuSend`             —— 局部变量
 *    · `_caps.loginQrSupported`    —— 私有字段
 *    · `showLoginEntry`            —— **getter 聚合**（loginSupported 的真实出口！）
 *
 *  ★ `loginSupported` 是最典型的例子：
 *    直接 grep `loginSupported` 在 UI 层**几乎零命中**，
 *    因为它被 `Capabilities.showLoginEntry => loginRequired || loginSupported`
 *    包了一层，UI 读的是 `showLoginEntry`。
 *    ⇒ 若不做映射，会**误报孤儿**。
 *  ```
 *
 *  # 表的结构
 *  ```text
 *  { 能力位名: [代码里可能的读取标识符...] }
 *  ```
 *  ⚠️ 不在表里的位 ⇒ 脚本会用「同名」兜底，并**显式报告"未映射"**
 *     （而不是静默当作"没读取点"）。
 * ══════════════════════════════════════════════════════════════════════ */
const DOC_TO_CODE = {
  vod: ['capabilities.vod', 'caps.vod', 'c.vod'],
  search: ['capabilities.search', 'caps.search', 'c.search'],
  live: ['capabilities.live', 'caps.live', 'c.live'],
  epg: ['capabilities.epg', 'caps.epg', 'c.epg'],
  favorites: ['capabilities.favorites', 'caps.favorites', 'c.favorites'],
  timeshift: ['capabilities.timeshift', 'caps.timeshift', 'c.timeshift'],
  serverSideHistory: [
    'capabilities.serverSideHistory',
    'caps.serverSideHistory',
    'c.serverSideHistory',
  ],
  danmaku: ['capabilities.danmaku', 'caps.danmaku', 'c.danmaku'],
  danmakuSend: ['capabilities.danmakuSend', 'caps.danmakuSend', 'c.danmakuSend'],
  /* ★ 聚合 getter —— 见上方注释 */
  loginSupported: ['showLoginEntry', 'capabilities.loginSupported', 'caps.loginSupported'],
  loginRequired: ['showLoginEntry', 'capabilities.loginRequired', 'c.loginRequired'],
  loginQrSupported: [
    'capabilities.loginQrSupported',
    'caps.loginQrSupported',
    '_caps.loginQrSupported',
  ],
  loginNeedsUsername: [
    'capabilities.loginNeedsUsername',
    'caps.loginNeedsUsername',
    '_caps.loginNeedsUsername',
  ],
  multiSource: ['capabilities.multiSource', 'caps.multiSource', 'c.multiSource'],
}

/* ══════════════════════════════════════════════════════════════════════
 *  参数
 * ══════════════════════════════════════════════════════════════════════ */
const argv = process.argv.slice(2)
const STRICT = argv.includes('--strict')
const docsIdx = argv.indexOf('--docs')

/** 默认文档：私库的 capability-bits.md（若存在）+ 本仓 PLUGINS.md */
function defaultDocs() {
  const out = []
  const pluginsDoc = join(REPO, 'docs', 'PLUGINS.md')
  if (existsSync(pluginsDoc)) out.push(pluginsDoc)
  // 私库通常在兄弟目录
  const sibling = resolve(REPO, '..', 'sourin-plugins', 'docs', 'capability-bits.md')
  if (existsSync(sibling)) out.push(sibling)
  return out
}

const DOCS =
  docsIdx >= 0 && argv[docsIdx + 1]
    ? argv[docsIdx + 1].split(',').map((s) => resolve(s.trim()))
    : defaultDocs()

const LIB = join(REPO, 'lib')

/* ══════════════════════════════════════════════════════════════════════
 *  工具
 * ══════════════════════════════════════════════════════════════════════ */

let hardFail = 0
const softNotes = []

function hard(cond, name, detail) {
  if (cond) {
    console.log(`  ✓ ${name}`)
  } else {
    hardFail++
    console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`)
  }
}

/**
 * 从文档里抽出「被描述的能力位名」
 *
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 抽取规则必须**只认"能力位语境"**（第一版严重误报，被实测打回）
 * ══════════════════════════════════════════════════════════════════════
 * ```text
 * 第一版规则：
 *   ① `### \`name\`` 小节标题
 *   ② `| \`name\` |` 速查表行
 *
 * 实测结果：抽出 **35** 个"能力位"，其中 21 个是假的 ——
 *   codec / drm / hdr / statusCode / json / message / retryable /
 *   playable / finalUrl / hosts / regex / verdict / streamFlags …
 *
 * 它们**不是能力位**，而是 `PLUGINS.md` 里代码示例中的
 * `StreamCandidate` / 错误对象字段：
 *     { url, kind, quality, codec, hdr, drm, … }
 *
 * ⇒ 21 个假孤儿，报告直接被噪声淹没 —— 而"每次都报一堆"的报告
 *   等于没有报告（这正是我们要避免的形态）。
 * ```
 *
 * # 修正后的规则（**三重收紧**）
 * ```text
 * ① 必须有「能力位语境」的**证据**，而不是只看格式像：
 *      · 出现在 `## 能力位` / `capabilities:` 之后的表格或小节
 *      · 或文档里有 `capabilities: { ... }` 代码块，取其顶层键
 * ② 显式**排除**已知的非能力位字段（StreamCandidate / 错误对象）
 * ③ 仍然允许 DOC_TO_CODE 里**已登记**的位直接通过（人工确认过的白名单）
 * ```
 *
 * ⇒ 宁可**少抓**（漏掉某个新能力位），也不可**乱抓**
 *   （把 StreamCandidate 字段当能力位 → 报告变噪声 → 没人看）。
 */

/** 已知的**非能力位**字段（来自 StreamCandidate / ProviderError / 配置项） */
const KNOWN_NON_CAPABILITY = new Set([
  // StreamCandidate
  'url', 'kind', 'quality', 'codec', 'hdr', 'drm', 'headers',
  'audioUrl', 'notWebReady', 'backupUrl', 'finalUrl', 'playable',
  // ProviderError / 错误对象
  'message', 'statusCode', 'retryable', 'unreachable', 'redirected',
  'needsHostResolve', 'not_a_stream', 'dash_unsupported', 'verdict',
  // 配置项 / 其他
  'json', 'regex', 'hosts', 'siteId', 'streamFlags', 'contentType',
  'config', 'id', 'name', 'version', 'kind_', 'timeout', 'proxy',
])

/**
 * 从文档里取「`capabilities: { ... }` 代码块中的顶层键」
 *
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 必须用**括号配平**，不能用正则找 `\n}`（第三版假阳性，被实测打回）
 * ══════════════════════════════════════════════════════════════════════
 * ```text
 * 第二版正则：/capabilities\s*:\s*\{([\s\S]*?)\n\s*\}/g
 *
 * 实测打回：PLUGINS.md:448 有**单行内联块**
 *     capabilities: { vod: true },
 *                      ↑ 这行没有 `\n  }`，于是正则的 `[\s\S]*?` 一路
 *                        滑到**下一个** `\n  }`（几十行之后）
 *     ⇒ 把 `hosts:` / `async list()` 等**块外**的键也吞进 capabilities
 *     ⇒ 排除表自检报「hosts 是真能力位」—— **假阳性**
 *
 * ⇒ 必须配平花括号：从 `{` 开始数，回到 0 就结束。
 * ```
 */
function extractCapabilityBlockKeys(text) {
  const keys = new Set()
  const re = /capabilities\s*:\s*\{/g
  let m
  while ((m = re.exec(text))) {
    const open = text.indexOf('{', m.index + m[0].length - 1)
    if (open < 0) continue
    // 配平
    let depth = 0
    let end = -1
    for (let i = open; i < text.length; i++) {
      if (text[i] === '{') depth++
      else if (text[i] === '}') {
        depth--
        if (depth === 0) {
          end = i
          break
        }
      }
    }
    if (end < 0) continue
    const body = text.slice(open + 1, end)
    // 只取**顶层**键（不深入嵌套对象）
    let d = 0
    let buf = ''
    const parts = []
    for (const ch of body) {
      if ('{[('.includes(ch)) d++
      if ('}])'.includes(ch)) d--
      if (ch === ',' && d === 0) {
        parts.push(buf)
        buf = ''
        continue
      }
      buf += ch
    }
    if (buf.trim()) parts.push(buf)
    for (const p of parts) {
      const k = /^\s*([a-zA-Z][\w]*)\s*:/.exec(p)
      if (k) keys.add(k[1])
    }
  }
  return keys
}

/**
 * @param {string} text 文档全文
 * @returns {Set<string>} 能力位名
 */
function extractBitsFromDoc(text) {
  const bits = new Set()

  /*
   * ① 从 `capabilities: { ... }` 代码块里取**顶层键**
   *    —— 这是最权威的来源（它就是能力位声明本身）
   *    ⚠️ 必须用 extractCapabilityBlockKeys（括号配平），不能用正则 —— 见该函数注释
   */
  for (const k of extractCapabilityBlockKeys(text)) {
    bits.add(k)
  }

  /*
   * ② `### \`name\` —— ...` 小节标题
   *    ⚠️ 但只在小节**内容提到"能力位"语境**时才算 ——
   *       否则 PLUGINS.md 里的 `### \`codec\`` 之类也会被误抓。
   *    判据：该小节正文（到下一个 ## 之前）出现
   *      「能力位」/「capabilities」/「声明 true」 之一。
   */
  const lines = text.split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const m = /^###\s+`([a-zA-Z][\w]*)`/.exec(lines[i])
    if (!m) continue
    // 收集该小节正文
    let body = ''
    for (let j = i + 1; j < lines.length; j++) {
      if (/^#{2,3}\s/.test(lines[j])) break
      body += lines[j] + '\n'
    }
    const capContext =
      /能力位|capabilities|声明\s*`?true`?/.test(body) || /能力位/.test(lines[i])
    if (capContext) bits.add(m[1])
  }

  /*
   * ③ `| \`name\` | 方法关/语义门 | ...` —— 速查表行
   *    ⚠️ 必须带「方法关 / 语义门」字样（那是本仓速查表的固定列）
   */
  for (const m of text.matchAll(/^\|\s*`([a-zA-Z][\w]*)`\s*\|\s*(方法关|语义门)/gm)) {
    bits.add(m[1])
  }

  /*
   * ④ 白名单：DOC_TO_CODE 里已登记的一律认
   *    （人工确认过是能力位，即便文档写法不规范）
   */
  for (const k of Object.keys(DOC_TO_CODE)) {
    // 只在文档确实提到这个词时才算
    if (new RegExp(`\\b${k}\\b`).test(text)) bits.add(k)
  }

  /* ⑤ 排除已知非能力位 */
  for (const k of [...bits]) {
    if (KNOWN_NON_CAPABILITY.has(k) && !DOC_TO_CODE[k]) bits.delete(k)
  }

  return bits
}

/** 递归收集 .dart 文件 */
function collectDart(dir, acc = []) {
  let entries
  try {
    entries = readdirSync(dir)
  } catch {
    return acc
  }
  for (const e of entries) {
    const p = join(dir, e)
    let st
    try {
      st = statSync(p)
    } catch {
      continue
    }
    if (st.isDirectory()) {
      if (e === 'build' || e === '.dart_tool' || e === 'node_modules') continue
      collectDart(p, acc)
    } else if (e.endsWith('.dart')) {
      acc.push(p)
    }
  }
  return acc
}

/**
 * 在 Dart 源码里找某个能力位的读取点
 *
 * # ★ 正则为什么不能排除 `.`（第二版假阳性，被实测打回）
 * ```text
 * 第一版：
 *   new RegExp(`(^|[^\\w.])${id}([^\\w]|$)`)
 *                        ↑ 排除点号，本意是避免 `research` 命中 `search`
 *
 * 实测：`danmakuSend` 被判**孤儿**，但它的真实读取点是
 *     lib/ui/player_page.dart:20587
 *       return hit?.capabilities.danmakuSend ?? false;
 *                                ↑ 前面是 `?.`（null-aware 访问）
 * ⇒ `[^\\w.]` 把 `.` 排除掉了 ⇒ **永远匹配不到** `caps.danmakuSend`
 *
 * ★ 教训：排除点号是错的。要防"research 命中 search"，
 *   只需保证**标识符左侧是词边界**（`[^\w]` 或行首），
 *   而**不**需要排除点号 —— `a.search` 里的 `search` 也是合法字段名。
 * ```
 *
 * @returns {Array<{file:string,line:number,text:string}>}
 */
function findReads(dartFiles, identifiers) {
  const hits = []
  for (const f of dartFiles) {
    let src
    try {
      src = readFileSync(f, 'utf8')
    } catch {
      continue
    }
    const lines = src.split(/\r?\n/)
    for (let i = 0; i < lines.length; i++) {
      const ln = lines[i]
      // 跳过纯注释行（// 或 /// 或 * 开头）
      const trimmed = ln.trim()
      if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) continue
      for (const id of identifiers) {
        const esc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
        /*
         * 左侧：行首 或 非词字符（**允许点号** —— 见上方说明）
         * 右侧：非词字符 或 行尾
         */
        const re = new RegExp(`(^|[^\\w])${esc}([^\\w]|$)`)
        if (re.test(ln)) {
          hits.push({ file: f, line: i + 1, text: trimmed.slice(0, 100) })
          break // 一行只记一次
        }
      }
    }
  }
  return hits
}

/* ══════════════════════════════════════════════════════════════════════
 *  主流程
 * ══════════════════════════════════════════════════════════════════════ */

console.log('══════ 软报告：能力位文档 ⇄ 代码接线 ══════\n')

/* ── 环境检查（硬判据 ①：扫描器必须真的能工作）── */
if (DOCS.length === 0) {
  console.error('✗ 找不到任何文档。用 --docs <path> 指定。')
  process.exit(2)
}
console.log(`① 文档（${DOCS.length} 个）`)
for (const d of DOCS) {
  console.log(`   · ${d}${existsSync(d) ? '' : '  ⚠ 不存在'}`)
}

/*
 * ★★★ 覆盖度显式提示（裁决 2：不许静默降级）
 *
 * # 为什么必须打印
 * ```text
 * CI 上没有兄弟目录的私库文档 ⇒ 只扫 docs/PLUGINS.md（6 个位），
 * 而 capability-bits.md 里的 8 个位**没被查**。
 *
 * 若静默跳过，汇总行「6 个能力位 — 已接线 6 / 孤儿 0」会被读成
 * 「全仓都接好了」—— 而实际只覆盖了 6/14。
 *
 * ★ 这与「状态④ 静默」是同一个病：**跳过即无声**。
 * ```
 */
const missingDocs = DOCS.filter((d) => !existsSync(d))
if (missingDocs.length > 0) {
  console.log('')
  for (const d of missingDocs) {
    console.log(`   ⚠ 未找到 ${d}`)
  }
  console.log(
    '   ⚠ 这些文档**本次未被检查** —— 其描述的能力位不进入统计。',
  )
  console.log('   ⚠ 若它们是私库文档，说明本机没检出那个仓库（CI 上正常）。')
}

const existingDocs = DOCS.filter((d) => existsSync(d))
hard(existingDocs.length > 0, '至少有一个文档存在', '全部路径都不存在')

if (!existsSync(LIB)) {
  console.error(`✗ 找不到 lib/：${LIB}`)
  process.exit(2)
}

const dartFiles = collectDart(LIB)
console.log(`\n② Dart 源码：${dartFiles.length} 个文件`)

/* ★ 硬判据 ②：扫描器必须扫到东西（作用域无关）*/
hard(dartFiles.length > 0, '扫到了 Dart 文件', `lib/ 下 ${dartFiles.length} 个`)

/* ── 抽取能力位 ── */
const allBits = new Map() // bit -> [来源文档 basename]
for (const d of existingDocs) {
  const text = readFileSync(d, 'utf8')
  for (const b of extractBitsFromDoc(text)) {
    if (!allBits.has(b)) allBits.set(b, [])
    allBits.get(b).push(basename(d))
  }
}

console.log(`\n③ 文档里描述的能力位：${allBits.size} 个`)
/* ★ 硬判据 ③：必须解析到能力位（作用域无关 —— 不要求具体几个）*/
hard(allBits.size > 0, '从文档解析到了能力位', '若为 0，说明抽取规则失效')

if (allBits.size === 0) {
  console.log(`\n${'═'.repeat(64)}`)
  console.log('❌ 扫描器自身失效（没解析到任何能力位）')
  process.exit(1)
}

/* ══════════════════════════════════════════════════════════════════════
 *  ★ 排除表自检（裁决 3）
 *
 *  # 为什么要自检（排除表会腐化）
 *  ```text
 *  `KNOWN_NON_CAPABILITY` 里现在有 codec / drm / hdr / statusCode …
 *  它们**当前**是 StreamCandidate 的字段，不是能力位。
 *
 *  但若将来真出现一个**叫 `drm` 的能力位**（例如"这个源支持 DRM 内容"），
 *  它会被这条排除表**静默吃掉** —— 报告里不出现，也没人知道它被排除了。
 *  ⇒ 排除表的每一项都必须有**依据**，不能靠"我记得它是字段"。
 *
 *  # 判据
 *  ```text
 *  排除表里的每个名字，若在文档的 `capabilities: { ... }` 代码块里出现
 *  ⇒ 说明文档把它当**能力位**在用 ⇒ **不该在排除表里** ⇒ 红
 *  ```
 *  ══════════════════════════════════════════════════════════════════════ */
console.log(`\n③-b 排除表自检（${KNOWN_NON_CAPABILITY.size} 项）`)

/** 从文档的 `capabilities: { ... }` 代码块里取到的**确定是能力位**的名字 */
const declaredAsCapability = new Set()
for (const d of existingDocs) {
  const text = readFileSync(d, 'utf8')
  for (const k of extractCapabilityBlockKeys(text)) {
    declaredAsCapability.add(k)
  }
}

const badExclusions = []
for (const name of KNOWN_NON_CAPABILITY) {
  if (declaredAsCapability.has(name)) badExclusions.push(name)
}

if (badExclusions.length > 0) {
  hard(
    false,
    '排除表里混进了真能力位',
    `${badExclusions.join(' / ')} 出现在文档的 capabilities 代码块里 ⇒ 不该被排除`,
  )
} else {
  hard(
    true,
    `排除表自检通过（${declaredAsCapability.size} 个已声明能力位里，无一被误排除）`,
  )
}

/* ── 逐个查读取点 ── */
console.log(`\n④ 逐个能力位：文档 ⇄ 代码\n`)

const wired = []
const orphans = []
const unmapped = []

const pad = (s, n) => {
  let w = 0
  for (const ch of s) w += /[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]/.test(ch) ? 2 : 1
  return s + ' '.repeat(Math.max(0, n - w))
}

for (const bit of [...allBits.keys()].sort()) {
  const identifiers = DOC_TO_CODE[bit]
  const isMapped = Array.isArray(identifiers)
  if (!isMapped) unmapped.push(bit)

  // 未映射 ⇒ 用同名兜底，但仍显式报告
  const ids = isMapped ? identifiers : [`capabilities.${bit}`, `caps.${bit}`, `c.${bit}`]
  const hits = findReads(dartFiles, ids)

  if (hits.length > 0) {
    wired.push({ bit, hits })
    const first = hits[0]
    const rel = first.file.slice(REPO.length + 1).replace(/\\/g, '/')
    console.log(
      `  ✓ ${pad(bit, 22)} 读取点 ${String(hits.length).padStart(3)} 处  首个：${rel}:${first.line}`,
    )
  } else {
    orphans.push({ bit, mapped: isMapped })
    console.log(`  ⚠ ${pad(bit, 22)} **孤儿**（文档说影响界面，代码里零读取点）`)
  }
}

/* ── 汇总（★ 含覆盖度）── */
console.log(`\n${'═'.repeat(64)}`)

/*
 * ★★★ 覆盖度必须显式（裁决 2）
 *
 * ```text
 * 「全量」= DOC_TO_CODE 里登记的能力位总数（那是"已知的全部能力位"）。
 * 「本次覆盖」= 本次文档里实际出现并检查了的位。
 *
 * 若只写「6 个能力位 — 全绿」，会被读成「全仓都接好了」——
 * 而实际只覆盖了 6/14。
 * ```
 */
const TOTAL_KNOWN = Object.keys(DOC_TO_CODE).length
const coverage = `${allBits.size}/${TOTAL_KNOWN}`
const notCovered = Object.keys(DOC_TO_CODE).filter((k) => !allBits.has(k))

console.log(
  `④ 汇总：${allBits.size} 个能力位（**覆盖 ${coverage}**）— ` +
    `已接线 ${wired.length} / 孤儿 ${orphans.length} / 未映射 ${unmapped.length}`,
)

if (notCovered.length > 0) {
  console.log(
    `   ⚠ 未覆盖的 ${notCovered.length} 个位（本次文档里没出现 ⇒ **未检查**）：`,
  )
  console.log(`     ${notCovered.join(', ')}`)
  console.log(
    '     ⇒ 若这些位在别的文档里（如私库 capability-bits.md），本地跑才覆盖。',
  )
}

if (orphans.length > 0) {
  console.log('\n⚠ 孤儿能力位（**软报告，不判失败**）：')
  for (const o of orphans) {
    console.log(`   · ${o.bit}${o.mapped ? '' : '（未在 DOC_TO_CODE 映射表里）'}`)
    softNotes.push(`孤儿能力位：${o.bit}`)
  }
  console.log('')
  console.log('   判断指引：')
  console.log('     · 若它**只影响一枚标签/一处小提示** ⇒ 可接受（如 danmaku）')
  console.log('     · 若文档说"显示入口/面板"却零读取点 ⇒ **文档在撒谎**，去修文档或接线')
}

if (unmapped.length > 0) {
  console.log('\n⚠ 未在映射表里的能力位（会用同名兜底，但建议补表）：')
  for (const u of unmapped) console.log(`   · ${u}`)
}

/*
 * ══════════════════════════════════════════════════════════════════════
 *  ★ 退出码三档语义（裁决 1）
 * ══════════════════════════════════════════════════════════════════════
 *
 * ```text
 *   0 = 跑完了（不管有没有孤儿）—— 报告正常产出
 *   1 = **扫描器自己坏了**（文档不存在 / 一个 dart 都没扫到 / 一个位都没解析到）
 *       ⇒ CI 必须红。这不是"发现问题"，是"检查本身失效"。
 *   2 = `--strict` 模式下有孤儿
 * ```
 *
 * # 为什么必须分开（裁决 1 的核心）
 * ```text
 * 原 CI 写法 `node ... || true` 把**脚本崩了**也吞掉。
 * 而「脚本崩了」与「孤儿位存在」是两件事：
 *   · 前者 ⇒ 这次什么都没查 ⇒ 必须红
 *   · 后者 ⇒ 可能是合法设计 ⇒ 只警告
 * ⇒ `|| true` 让两者都变成绿 ⇒ 扫描器坏掉时**静默**。
 * ```
 */
console.log(`\n${'═'.repeat(64)}`)

if (hardFail > 0) {
  console.log(`❌ 扫描器自身有 ${hardFail} 个问题（见上）`)
  console.log('   ⇒ 退出码 1：本次**没有产出可信报告**')
  process.exit(1)
}

if (STRICT && orphans.length > 0) {
  console.log(`⚠ （--strict）孤儿位 ${orphans.length} 个 ⇒ 退出码 2`)
  process.exit(2)
}

console.log('✅ 扫描器正常工作（孤儿位属软报告，退出码 0）')
console.log(`   覆盖度 ${coverage}${notCovered.length > 0 ? `（未覆盖 ${notCovered.length} 个，见上）` : '（全覆盖）'}`)
process.exit(0)
