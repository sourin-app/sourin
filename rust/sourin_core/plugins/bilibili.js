/**
 * @id          bilibili
 * @name        哔哩哔哩
 * @version     2.0.0
 * @author      dsh
 * @description 哔哩哔哩（直播直播间）+ 点播能力位（点播侧待补，见下）
 * @homepage    https://www.bilibili.com
 *
 * ═══════════════════════════════════════════════════════════════════════
 *  ★★★ 本插件是「直播 + 点播」一体的，不存在「直播插件」这个类别
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 架构口径（Owner 逐字）：
 * ```text
 * 客户端只提供「直播能力」，不内置任何插件；
 * 直播与点播**不区分** —— 点播和直播都是插件提供的能力，
 * js 插件里的 capabilities 那个只是**做筛选**。
 * ⇒ 一个插件**同时**声明 vod 与 live，不存在"直播插件"这类东西。
 * ```
 *
 * # 本文件的历史（★ 违反过上面那条，已纠正）
 *
 * 它原名 `bilibili-live.js`，`@id` 是 `bilibili-live`，
 * `capabilities` 写的是 `{ vod: false, live: true }` ——
 * ★ **把自己做成了一个"直播插件"**，正是被纠正的形态。
 * 文件头当时还论证过"为什么单开一个插件而不是塞进 bilibili.js"：
 * ```text
 * 那段理由的核心是"bilibili.js（点播）不在本仓库里、改不到用户手上"。
 * ★ 但那条理由**不成立**：本仓库本来就按 @id 释放/覆盖插件
 *   （见 state.rs::seed_managed_plugin），仓库里的 bilibili.js
 *   会随版本升级覆盖到用户数据目录。⇒ 那段理由作废，已删。
 * ```
 *
 * ⚠️ 现在叫 `bilibili.js`、`@id` 是 `bilibili` ——
 *    **这会覆盖用户数据目录里那份手写的点播 `bilibili.js`**
 *    （只要它版本号低于 2.0.0，见下「迁移」一节）。
 *    这是 Owner 要的形态：一个 bilibili 源，同时管直播与点播。
 *
 * ═══════════════════════════════════════════════════════════════════════
 *  ⚠️⚠️ 点播侧（vod）当前**没有实现** —— 这是如实声明的现状
 * ═══════════════════════════════════════════════════════════════════════
 *
 * ```text
 * 本仓库里**只有直播侧**被实测跑通（liveChannels / liveStream，见下）。
 * 点播侧的函数（home / categories / list / detail / resolve / search）
 * ★ **本文件一个都没写** —— 不写假实现（"不要凭空实现"）。
 * ```
 *
 * 那为什么 `capabilities.vod` 仍声明 **true**？—— 这是**实测过**的决定，
 * 不是拍脑袋：
 * ```text
 * 问题：声明 vod:true 会不会因为缺 home/categories/detail 而**加载失败**？
 * 实测（读源码，非推测）：**不会**。
 *   · `hydrate_capabilities()`（plugins/mod.rs:553）只执行脚本读
 *     `globalThis.plugin.capabilities` 的**布尔值** ——
 *     ★ 它**不检查**对应函数是否存在。能力位与函数**不是一一对应**的。
 *   · 所以 vod 是 true 还是 false，插件都能加载、都能注册。
 * ⇒ 既然不因缺函数失败，就按 Owner 的口径声明 `vod: true`
 *   （本插件是 vod+live 一体的）。
 * ```
 *
 * ⚠️ 但**必须知道**声明 `vod:true` 的**一个真实副作用**（别当没看见）：
 * ```text
 * Flutter 首页用 `providesHomeContent(p) <=> p.capabilities.vod`
 * （lib/ui/home_page.dart:130）决定"这个源进不进首页的源切换条"。
 * ⇒ vod:true ⇒ 本插件会出现在首页源条里；
 *   而它的 home()/categories() 没实现 ⇒ 选中它时首页是**空态**。
 * ★ 这是"点播侧待补"的直接表现，不是 bug —— 点播侧补上后自然消失。
 * ```
 * ⇒ **待办**：补齐点播侧（热门 / 排行 / 搜索 / 详情 / 取流）后，
 *   把上面那句"空态"的说明删掉。在那之前，本段注释就是它的
 *   唯一"施工中"标识。
 *
 * ═══════════════════════════════════════════════════════════════════════
 *  ★ 旧文件迁移：`bilibili-live.js` 必须被删除
 * ═══════════════════════════════════════════════════════════════════════
 *
 * 老用户数据目录里躺着旧插件 `bilibili-live.js`（`@id: bilibili-live`）。
 * 插件扫描器（`plugins/mod.rs::load_plugins`）的判据是
 * ★ **"扩展名是 .js 就加载"**，**不是**按文件名白名单：
 * ```text
 * for e in read_dir(dir) { if ext == "js" { JsPluginProvider::from_source(..) } }
 * ```
 * ⇒ 光把本文件改名**不够**：旧的 `bilibili-live.js` 仍会被扫到并加载，
 *   于是用户会同时看到**两个**哔哩哔哩直播源
 *   （一个 `bilibili-live` 旧版 + 一个 `bilibili` 新版）——
 *   频道列表翻倍、重复，且没有任何报错。
 *
 * ⇒ 因此在 `state.rs::seed_bilibili_plugin()` 里**显式删除**旧文件
 *   （清理时机与理由见那里的注释）。本注释与那段代码是配套的，
 *   改一处必须改另一处。
 *
 * ═══════════════════════════════════════════════════════════════════════
 *  实测结论（2026-10-13，本机直连、游客态、无任何 Cookie）
 * ═══════════════════════════════════════════════════════════════════════
 *
 * ① **游客就能看直播**，不需要登录
 * ```text
 * GET api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=…  -> code=0
 * ```
 * ⇒ 与点播一致（点播游客也能看 1080P）。所以本插件 **loginRequired: false**。
 *
 * ② ★★ **取流地址必须带 Referer + UA，否则 403**（实测，与点播同一个坑）
 * ```text
 * 同一条 m3u8：
 *   不带任何头        -> HTTP 403
 *   Referer + UA      -> HTTP 200 + 合法 #EXTM3U
 * ```
 * ⇒ 播放候选**必须**带 `headers` + `notWebReady: true`（由宿主代理转发）。
 *   这正是点播那边注释里记录的同一个 CDN 防盗链行为。
 *
 * ③ **HLS 与 FLV 都可用，优先 HLS**
 * ```text
 * protocol=0,1 + format=0,1,2 的返回里两条协议都在：
 *   http_stream -> flv   （avc / hevc）
 *   http_hls    -> ts / fmp4（avc / hevc）
 * ```
 * 选 HLS 的原因：直播页/播放器对 HLS 的处理路径**已经是验证过的**
 * （`iptv.js` 全量返回 kind:'hls'），而 FLV 要额外验证一遍。
 * 「用已走过的路」比「用看起来更原始的路」风险低。
 * ⇒ 请求参数固定 `protocol=1`（只要 HLS），省掉一半无用字段。
 *
 * ④ **必须挑 avc，不能挑 hevc**（同点播那份的结论）
 * ```text
 * B 站每个清晰度同时给 avc 与 hevc 两条；播放器不支持 hvc1
 * ⇒ 选了 hevc 会**黑屏**（有声音有进度，就是没画面）。
 * ```
 * ⇒ 组装候选时按 `codec_name === 'avc'` 过滤。
 *
 * ⑤ **房间列表用「热门推荐」接口**（`xlive/web-interface/v1/index/getList`）
 * ```text
 * 返回 data.room_list[]（若干模块），每个模块有 .list[]（房间数组）。
 * 实测每个模块给一堆房间，取推荐的第一个模块即可。
 * ```
 * ⚠️ 为什么**不**拉全站分区房间：那会上万个。
 *   直播页对**每个频道**都要跑一次 `getLiveStream` 探测可用性
 *   （见 `lib/ui/live_availability.dart`）——
 *   频道数直接等于进页面时的网络请求数。
 *   ⇒ 必须**限量**（见 MAX_ROOMS），否则用户一进直播页就被打爆。
 *
 * ⑥ **房间会在任意时刻开播/下播** —— 列表是**易变**的
 * ```text
 * getRoomPlayInfo 的 live_status：0=未开播 1=直播中 2=轮播
 * ```
 * ⇒ 下播的房间返回的 playurl 是空的 ⇒ 如实报错（not_found），
 *   而不是给一个播不了的空候选。缓存 TTL 取短（见 CACHE_TTL_MS）。
 *
 * ═══════════════════════════════════════════════════════════════════════
 *  ⚠️ 本插件**不导入 Cookie / 不涉及登录态**
 * ═══════════════════════════════════════════════════════════════════════
 * 「热门推荐」与「取流」都是游客接口。不碰凭据 = 少一处泄露面，
 * 也少一处需要用户配置的地方。将来若要做「关注的主播直播间」再谈登录。
 */

/**
 * 直播接口域名
 *
 * ⚠️ 与点播的 `api.bilibili.com` **不是同一个** —— 直播全在
 *    `api.live.bilibili.com`。写错域名会拿到 404（不是风控，更容易误判）。
 */
const LIVE_API = 'https://api.live.bilibili.com'

/**
 * 请求头 —— 实测「热门推荐」不带也能通，但带上更稳
 *
 * ⚠️ 真正的关键在**取流**（见 PLAY_HDRS）—— 列表接口的头可省，
 *    但两处统一用一套，避免"哪处该带"这种要靠记忆的知识。
 */
const HDRS = {
  Referer: 'https://live.bilibili.com/',
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
}

/**
 * ★★★ 取流请求头 —— **缺了必然 403**（实测，不是推测）
 *
 * 与点播侧记录的**完全同源**的 CDN 行为：
 * 只带 Referer 是不够的，reqwest 默认不发 UA ⇒ WAF 按"请求头完整性"
 * 判定是不是正常播放器。
 *
 * ⚠️ `notWebReady: true` 也必须带上 —— 播放器（MSE / <video>）
 *    **加不了自定义请求头**，只能由宿主用本地代理转发（`streamproxy`）。
 *    这是 `model.rs::StreamCandidate.not_web_ready` 存在的意义。
 */
const PLAY_HDRS = {
  Referer: 'https://live.bilibili.com/',
  Origin: 'https://live.bilibili.com',
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  Accept: '*/*',
  'Accept-Language': 'zh-CN,zh;q=0.9',
}

/**
 * 频道数上限
 *
 * # 为什么是 40（而不是"有多少显示多少"）
 * ```text
 * 直播页进页面时对**每个频道**调一次 getLiveStream 探测可用性
 * （见 lib/ui/live_availability.dart 的 LiveAvailabilityProbe）。
 * ⇒ 频道数 = 进页面的网络请求数。
 * ⇒ 拉全站分区（上万个）会把用户网络与 B 站接口一起打爆，
 *   而且首屏永远出不来。
 * ```
 * 40 是"够翻、又不至于让探测变慢"的经验值：实测 40 路（并发 8）
 * 的中位耗时与 20 路同量级。
 * ⚠️ 不做分页 —— 直播是"现在有什么看什么"，翻到第 5 页的房间
 *    大概率已经下播了（列表本身就在变）。
 */
const MAX_ROOMS = 40

/**
 * 房间列表缓存（`host.store`，插件私有）
 *
 * # 为什么 TTL 只有 5 分钟（点播那边是 6 小时）
 * ```text
 * 点播列表（热门/排行）是**低频变化**的数据 —— 几小时内基本不变。
 * 直播房间是**高频变化**的：主播随时开播/下播，
 * ⇒ 缓存太久会让用户看到一堆"已经下播"的房间，点进去全是 not_found。
 * ```
 * ★ 但也不能不缓存：`liveChannels()` 与 `liveStream()` 都会读列表，
 *   同一个页面生命周期内至少要读两次，每次都打网络没必要。
 *
 * ⚠️ key 带 `v1` 结构版本 —— 改缓存结构时改它（本仓 `iptv.js` 的教训：
 *    光换 key 不够，还要 <cacheValid> 校验结构，见下）。
 */
const CACHE_KEY = 'rooms_v1'
const CACHE_TTL_MS = 5 * 60 * 1000

/**
 * 缓存结构校验（第二层保险）
 *
 * ⚠️ 只认"有房间号 + 有标题"的表。
 *    结构不对 => 返回 false => 重新拉取（而不是把坏数据喂给界面）。
 *    —— 这一层不依赖"我有没有记得改 CACHE_KEY"。
 */
function cacheValid(c) {
  if (!c || !c.at || !Array.isArray(c.rooms) || !c.rooms.length) return false
  return c.rooms.slice(0, 3).every((x) => x && x.id && x.name)
}

/* ───────────────────────────── HTTP ───────────────────────────── */

/**
 * 发 JSON 请求
 *
 * 宿主 `host.http.get` 的契约（见 `plugins/mod.rs::do_http`）：
 * ```text
 * 成功 -> 返回**响应体文本**
 * 失败 -> 返回以 `__ERR__` 开头的串（**不抛异常**，必须自己查前缀）
 * ```
 * ★ 不查前缀的后果：把 `__ERR__HTTP 403: …` 丢给 `JSON.parse`，
 *   报的是"返回不是合法 JSON"—— 排查方向完全错了。
 */
async function getJson(url, headers) {
  const text = await host.http.get(url, { headers: headers || HDRS })
  if (text.startsWith('__ERR__')) {
    throw new Error('network: ' + text.slice(7))
  }
  let j
  try {
    j = JSON.parse(text)
  } catch {
    throw new Error('parse: 返回不是合法 JSON — ' + text.slice(0, 120))
  }
  /*
   * ⚠️ B 站的业务状态码在 body 的 `code` 里，**HTTP 状态仍是 200**。
   *    `code != 0` 必须自己判 —— 否则会把错误体当成正常数据用。
   *    -352 = 限流 / 风控（退避重试），-400 = 参数错。
   */
  if (j && typeof j.code === 'number' && j.code !== 0) {
    throw new Error('upstream: B站接口返回 code=' + j.code + ' ' + (j.message || j.msg || ''))
  }
  return j
}

/* ─────────────────────── 房间列表（热门推荐）─────────────────────── */

/**
 * 拉热门推荐房间表，带缓存
 *
 * @returns {Promise<Array<{id:string,name:string,logo?:string,group?:string}>>}
 */
async function loadRooms(force) {
  if (!force) {
    try {
      const raw = host.store.get(CACHE_KEY)
      if (raw) {
        const c = JSON.parse(raw)
        if (cacheValid(c) && Date.now() - c.at < CACHE_TTL_MS) {
          return c.rooms
        }
      }
    } catch {
      /* 缓存读坏 => 当没有，走下面的重新拉取 */
    }
  }

  /*
   * ⚠️ 参数固定 `parent_area_id=1&area_id=0&sort_type=online`：
   *    实测这是"推荐"模块入口。`area_id=0` 表示"该父分区全部"。
   *    不传 area_id 时接口对部分父分区返回空 list（实测 parent_area_id=1 可以）。
   */
  const url =
    LIVE_API +
    '/xlive/web-interface/v1/index/getList?platform=web' +
    '&parent_area_id=1&area_id=0&sort_type=online&page=1'
  const j = await getJson(url)
  const modules = (j.data && j.data.room_list) || []

  /*
   * `room_list` 是**若干模块**（推荐 / 各父分区入口），每个模块有 `.list`。
   * 逐个模块展开，去重后取前 MAX_ROOMS 个。
   *
   * ★ 去重按 roomid：同一个热门房间可能同时出现在"推荐"与"所属分区"两个模块里。
   *   不去重会让频道列表出现重复项（用户看到两个一模一样的台）。
   */
  const seen = new Set()
  const rooms = []
  for (const m of modules) {
    for (const r of m.list || []) {
      const id = String(r.roomid || '')
      if (!id || seen.has(id)) continue
      // 房间必须有标题 —— 没有标题的多半是空占位卡片（实测确实存在）
      const name = String(r.title || '').trim()
      if (!name) continue
      seen.add(id)
      rooms.push({
        id,
        /*
         * 频道名 = 直播标题。
         *
         * ⚠️ 为什么不用主播名（`uname`）：直播页要的是"现在在播什么"，
         *   标题正是它（如「【直播】WE vs FLY」）。
         */
        name,
        // 封面当台标 —— 这是房间当前画面的封面，比默认头像更有辨识度
        logo: r.cover || r.user_cover || r.system_cover || undefined,
        // 分组用**父分区名**（如「手游」「赛事」）—— 与 iptv.js 的中文分组同形
        group: r.area_v2_parent_name || '哔哩哔哩',
      })
      if (rooms.length >= MAX_ROOMS) break
    }
    if (rooms.length >= MAX_ROOMS) break
  }

  /*
   * ★ 只有**拿到了东西**才写缓存。
   *   空结果写缓存 = 把一次失败放大成 5 分钟的失败
   *   （本仓 get_live_stream 缓存同一条规矩，见 sourin_api.dart 的注释）。
   */
  if (rooms.length) {
    try {
      host.store.set(CACHE_KEY, JSON.stringify({ at: Date.now(), rooms }))
    } catch {
      /* 存不下不影响本次返回 */
    }
  }
  return rooms
}

/* ─────────────────────── 取流 ─────────────────────── */

/**
 * 从 `getRoomPlayInfo` 的返回体里挑出**一路** HLS 地址
 *
 * # 返回结构（实测，字段路径逐级确认过）
 * ```text
 * data.playurl_info.playurl.stream[]         <- 协议层：http_stream / http_hls
 *   .protocol_name === 'http_hls'
 *   .format[]                                <- 封装层：ts / fmp4
 *     .codec[]                               <- 编码层：avc / hevc
 *       .codec_name === 'avc'                ★ 必须挑 avc（见文件头 ④）
 *       .base_url                            <- 路径（**相对**，要拼 host）
 *       .url_info[0].{host, extra}           <- 主机 + 查询串（含签名）
 * ```
 *
 * # ★ 地址是「host + base_url + extra」三段拼的，**不是**一个完整 URL
 * ```text
 * host     = https://d1--cn-gotcha104.bilivideo.com
 * base_url = /live-bvc/643136/live_50329118_9516950_2500.m3u8?
 * extra    = expires=…&sign=…&cdn=…
 * => 三者拼接才是可播地址。漏掉 extra 会 403（签名没了）。
 * ```
 *
 * # 多档清晰度怎么选
 * ```text
 * codec[] 是**同一档清晰度**的多个 CDN 镜像（url_info[]）+ 不同编码。
 * 而不同清晰度在**不同 format/codec 项**的 accept_qn 里，
 * 每一项自带 current_qn。
 * => 这里取 accept_qn 的**最大值**所在项 —— 即该房间能给的最高档；
 *   拿不到 accept_qn 就退回第一个 avc 项。
 * ```
 *
 * @returns {{url:string, quality?:string} | null}
 */
function pickHls(data) {
  const streams = (data && data.playurl_info && data.playurl_info.playurl
    && data.playurl_info.playurl.stream) || []

  const hls = streams.find((s) => s.protocol_name === 'http_hls')
  if (!hls || !Array.isArray(hls.format)) return null

  // 摊平成所有 avc 编码项
  const avcItems = []
  for (const f of hls.format) {
    for (const c of f.codec || []) {
      if (c.codec_name !== 'avc') continue
      const ui = (c.url_info || [])[0]
      if (!ui || !ui.host || !c.base_url) continue
      const qn = Array.isArray(c.accept_qn) && c.accept_qn.length
        ? Math.max.apply(null, c.accept_qn)
        : (c.current_qn || 0)
      avcItems.push({ url: ui.host + c.base_url + (ui.extra || ''), qn })
    }
  }
  if (!avcItems.length) return null

  // 取最高清晰度；并列时保持原顺序（第一个 CDN）
  avcItems.sort((a, b) => b.qn - a.qn)
  return avcItems[0]
}

/**
 * 清晰度码 -> 中文标签
 *
 * 实测该接口的 `g_qn_desc` 会带上这些（这里固化的是常用档，
 * 未命中回落 `原画`，不塞"未知"—— 直播默认就是原画）。
 */
const QN_LABEL = {
  30000: '杜比',
  20000: '4K',
  15000: '2K',
  10000: '原画',
  400: '蓝光',
  250: '超清',
  150: '高清',
}

/* ─────────────────────── 插件出口 ─────────────────────── */

globalThis.plugin = {
  id: 'bilibili',

  capabilities: {
    /*
     * ★★ vod / live 都声明 true —— 本插件是**一体**的（见文件头）。
     *
     * ⚠️ 与函数**不是一一对应**：能力位只是"这个源提供哪类内容"，
     *    `hydrate_capabilities()` 只读布尔值，**不校验对应函数是否存在**
     *    ——实测，plugins/mod.rs:553）。
     * ⇒ 下面**没有** home/categories/list/detail/resolve/search
     *   （点播侧待补），但 vod 仍按 Owner 口径声明 true。
     *   声明 true 的真实副作用（会进首页源条、选中时空态）见文件头。
     */
    vod: true,
    live: true,
    // 直播没有节目单（EPG 是电视台的概念，直播间只有"正在播什么"= 标题）
    epg: false,
    /*
     * ⚠️ `search: false` —— **如实**：搜索只可能来自点播侧，
     *    而点播侧本文件没实现 ⇒ 不能声明 true（否则
     *    `Registry::search_all()` 会把这个源算进搜索，
     *    而它没有 `search()` 方法 ⇒ 每次搜索都报 not a function）。
     *    点播侧补齐时再改 true。
     */
    search: false,
    /*
     * ★ 游客可看 => **不要**设 loginRequired。
     *   设了会让 Registry::ensure_session 挡住游客路径（本仓已有教训：
     *   点播侧若设成必需登录，会丢掉"游客看 1080P"这个关键能力）。
     */
    loginRequired: false,
  },

  /**
   * 直播频道列表
   *
   * ⚠️ 契约：`id` 用**裸房间号**（不带 provider 前缀）——
   *    宿主会自动加前缀，且 `liveStream(channelId)` 收到的也是裸值。
   */
  async liveChannels() {
    const rooms = await loadRooms(false)
    return rooms.map((r) => ({
      id: r.id,
      name: r.name,
      logo: r.logo,
      group: r.group,
    }))
  },

  /**
   * 取一路直播流
   *
   * # 为什么这里**必须**发网络请求（不能像 iptv.js 那样从列表里取）
   * ```text
   * iptv.js 的频道地址是 m3u 里的**固定地址** => 缓存列表即可，取流零网络。
   * B 站直播地址是**每次现签的**（extra 里的 expires / sign 有时效），
   * => 必须用 room_id 现场换地址。这是接口模型决定的，绕不过去。
   * ```
   * ⚠️ 代价：直播页的可用性探测会对每个频道打一次本函数。
   *    这是频道数要限量（MAX_ROOMS）的根本原因。
   */
  async liveStream(channelId) {
    /*
     * ⚠️ 前缀兼容：历史上本插件 `@id` 是 `bilibili-live`，
     *    老版本可能把 `bilibili-live:<房间号>` 传进来 —— 一并剥掉，
     *    两种前缀都认（迁移期容错，`bilibili:` 是新前缀）。
     */
    const id = String(channelId || '').replace(/^(bilibili-live|bilibili):/, '')
    /*
     * ⚠️ 房间号必须是纯数字：非数字说明传进来的不是本插件的频道 id
     *    （可能是别的源串了，或上游契约变了）=> 明确报错，
     *    而不是拼一个非法 URL 去撞接口。
     */
    if (!/^\d+$/.test(id)) {
      throw new Error('not_found: 无效的直播间号 ' + id)
    }

    /*
     * 参数说明（实测确认）：
     *   protocol=1              只要 http_hls（见文件头 ③）
     *   format=1,2              ts / fmp4 两种封装都要（有些房间给 fmp4）
     *   codec=0                 只要 avc（=0 是 avc，1 是 hevc）
     *   qn=10000                请求原画（服务端按权限降级，游客也能拿到）
     *   platform=web&ptype=8    网页端标识（不传时接口对部分房间返回空）
     *   dolby=5&panorama=1      与前两项配套的默认值，去掉会少字段
     */
    const url =
      LIVE_API +
      '/xlive/web-room/v2/index/getRoomPlayInfo?room_id=' + encodeURIComponent(id) +
      '&protocol=1&format=1,2&codec=0&qn=10000&platform=web&ptype=8&dolby=5&panorama=1'
    const j = await getJson(url)
    const data = j.data || {}

    /*
     * ⚠️ `live_status`：0=未开播 1=直播中 2=轮播
     *    未开播时 playurl_info 为 null => 这里先给一句**人能看懂**的话，
     *    否则用户点到一个下播的房间只会看到"取不到播放地址"（不知道是下播了）。
     */
    if (data.live_status === 0 || !data.playurl_info) {
      throw new Error('not_found: 这个直播间当前不在直播（可能已下播）')
    }

    const pick = pickHls(data)
    if (!pick) {
      throw new Error('not_found: 这个直播间没有可用的 HLS 线路（可能是付费/特殊直播间）')
    }

    return [
      {
        url: pick.url,
        kind: 'hls',
        quality: QN_LABEL[pick.qn] || '原画',
        label: '哔哩哔哩直播',
        /*
         * ★★ 这两个字段**缺一不可** —— 缺了就是 403 黑屏（实测，见文件头 ②）
         *    headers      ：防盗链请求头，由宿主代理转发时注入
         *    notWebReady  ：告诉宿主"播放器自己加不了头，必须走你的代理"
         */
        headers: PLAY_HDRS,
        notWebReady: true,
      },
    ]
  },
}
