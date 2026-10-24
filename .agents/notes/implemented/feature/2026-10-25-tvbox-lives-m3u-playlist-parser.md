# Agent Note: 补 m3u/txt 播放列表解析器，让 TVBox 的 lives[] 能真正导入

Status: implemented

与既有决定的关系（补缺口，不取代）：既有 `src/tvbox.rs::collect_sites` 早已把
配置里的 `lives[]`（`{name,url}`）提取出来，但注释明写「**本版本不导入**，只如实回报」
—— 因为当时**没有播放列表解析器**，拿不到频道。本笔记补的就是这一跳。
那份 4526 行实现本身不动。

Independent: 本仓此前**没有任何播放列表解析的决策**。`streamproxy.rs` 里那些 `#EXTM3U` / `#EXT-X-KEY` 处理是 **HLS 媒体清单**（分片、密钥、码率），与**播放列表**（`#EXTINF` + 台名 + 地址）是两种格式，不能互相替代；既有 `src/tvbox.rs` 只是把 `lives[]` 原样透出，也没有做解析。因此本模块不与任何既有决定重叠或冲突。

## Problem

TVBox 配置的 `lives[]` 是一组直播源地址，指向 `.m3u` 或 `.txt` 播放列表。
本仓此前只能把这份清单原样回报给 UI，用户看得到"有 2 个直播源"却用不了。

障碍是缺一层解析：URL 里的文本 → `LiveChannel` 列表。
本仓只有 HLS manifest（`#EXT-X-KEY` 那些）的处理，**不是**播放列表解析。

## Decision

新增 `src/m3u.rs::parse_playlist(text, source_key) -> Vec<LiveChannel>`：

1. **自动识别两种格式**
   - m3u：`#EXTM3U` / `#EXTINF` 头 + `tvg-logo` / `group-title` / `tvg-name` 属性
   - 朴素 txt：`名字,url`（部分列表还带 `url$分组`）
   判据是前 5 行里出现 `#EXTM3U`/`#EXTINF`，否则按 txt 解析。

2. **宽容解析，但绝不编造**
   - 属性缺失 ⇒ 字段 `None`（**不是空串** —— 空串会让 UI 画出空白 logo 位）
   - 一行坏掉 ⇒ 只跳过那一行，继续解析后面的
   - 剥 BOM、跳注释、跳空行
   - `is_playable_url` 只收带 scheme 的地址；相对路径/裸文本一律丢
     （那些是解析失败的残渣，收进来只会变成点不开的台）

3. **id 必须稳定**：`{源key}::{序号}::{FNV-1a(url)}`
   同样输入重解析必须产出同样 id，否则用户"上次看的台"每次刷新都丢。
   FNV-1a 足够（只拼 id，不需要抗碰撞）。

4. **名字里带逗号不能被截断**：`#EXTINF` 的属性和显示名用
   **引号外第一个逗号**切分 —— 真实列表里 `新闻,综合` 这种名字很常见。

5. **属性键必须整词匹配**：`x-tvg-name` 不许冒充 `tvg-name`。
   实现上逐个候选位置试，而不是只看第一个 `find` 的结果。

## Alternatives considered

### A. 只支持标准 m3u，不支持朴素 txt
**最强理由**：m3u 有明确规范，txt 各家写法不一，维护成本低。
**否掉的原因**：实测这份 TVBox 配置的 `lives[0].url` 就是
`http://iptv.ruyitv.cc/m3u/tv.txt` —— **就是朴素 txt**。只支持 m3u 等于
"给了一个用不了的功能"。

### B. 用现成的 `m3u8-rs` crate 解析
**最强理由**：不重复造轮子，规范覆盖更全。
**否掉的原因**：`m3u8-rs` 是 **HLS 媒体清单**解析器（`#EXT-X-*` 分片），
与**播放列表**（`#EXTINF` + 台名 + URL）不是同一个格式，硬套反而要写转换层。
本仓 `Cargo.toml` 也没引入它。

### C. 解析失败时返回 Err，让调用方决定
**最强理由**：语义清晰，不掩盖问题。
**否掉的原因**：真实直播列表**普遍**混着注释、空行、半截 URL。
整体失败会让"99 个好台 + 1 个坏行"的列表一个都导不进来。

### D. 名字缺失时用 URL 里的台名/序号（如"频道1"）
**最强理由**：UI 上不留空白。
**否掉的原因**：那是**编造**。用 URL 尾段（如 `ch1`）还算有依据，
编号"频道1"则完全是假的。当前实现只做前者。

## 验证结果（已发生）

- `cargo test --lib m3u --release` → **13 passed**
  覆盖：标准 m3u 属性、朴素 txt、坏行跳过、名字带逗号、属性缺失为 None、
  id 稳定、老协议保留而相对路径丢弃、`x-tvg-name` 不串键、空输入、BOM。
- **故障注入**：把 `is_playable_url` 改成恒 `true` ⇒
  `bad_lines_are_skipped_not_fatal` 与
  `legacy_protocols_are_accepted_but_relative_paths_are_not` **双双 FAILED**，
  恢复后 13 passed。证明"垃圾行不许混进来"这条真能变红。


## 追加：接入层 `M3uLiveProvider`（同一决定的落地）

解析器只是纯函数，用户看不到东西。要让它变成"能看的直播源"，必须做成
**provider** —— 因为直播页取数是
`get_live_channels → registry.live_all() → 每个 provider 的 live_channels()`。
绕开 registry 直接塞数据就得改直播页取数链路，而且"刷新""取流"无处安放。

`src/providers/m3u_live.rs`：

- **一个播放列表 URL = 一个 provider**：TVBox 的每个 `lives[i]` 是独立列表，
  manifest.id 由 `m3u::stable_key(url)` 派生 ⇒ **同一地址重复导入不产生第二个源**
- `live_channels()` **每次重拉**（列表会增删台），解析结果填进
  `HashMap<频道id, 播放地址>` 缓存
- `live_stream(id)` 走缓存反查地址 —— 切台是高频调用，每次重拉整个列表会卡
- `LiveChannel` 模型**故意没有**播放地址字段（频道列表不该把地址泄露到 UI 层）
  ⇒ `m3u.rs` 新增 `parse_playlist_with_urls()` 返回 `(频道, 地址)` 对，
  两个入口共用同一套解析逻辑，不重复实现
- 点播方法（`list`/`detail`/`resolve`）**明确返回 unsupported**，
  不返回空页 —— 否则 UI 会显示"暂无内容"而不是"这个源本来就没有点播"

验证：`cargo test --lib m3u` → **18 passed**（含 provider 5 条）；
注入"用地址长度当 id"（模拟不稳定 id）⇒
`id_is_derived_from_url_so_reimport_is_stable` **FAILED**，恢复后复绿。

**仍未做**：持久化（`PersistedProvider` 还没有 m3u 变体）、
`import_tvbox_config` 也还没把 lives 注册进去 ⇒ **用户目前仍看不到直播源**。

## Consequences

**收益**
- TVBox `lives[]` 从"只回报"变成"可解析"：拿到文本就能产出频道列表，
  这一步不依赖网络也不依赖 Java，纯函数、可离线测。
- 解析器与 TVBox 解耦（放在 `src/m3u.rs` 而不是 `tvbox.rs`），
  将来"用户自己贴一个 m3u 地址"也能直接复用。

**代价 / 尚未做的**
- **还没有接进直播链路**：`parse_playlist` 目前只是个纯函数，
  没有 provider 包装、没有持久化、`import_tvbox_config` 仍只回报不导入。
  这是下一步（P1'.2 的剩余部分）。
- 只解析**列表**，不解析频道里的多清晰度；一个台多个源会被当成多个台
  （真实列表里通常也是这么列的，暂时按原样呈现）。
- txt 的 `url$分组` 是我在样本里见到的写法，不是规范；
  其它变体（如 `名字,url,分组`）当前不认，会被当成 URL 含逗号而丢弃。
