// ═══════════════════════════════════════════════════════════════════════
//  详情与播放链路 —— 从 Tauri lib.rs 搬过来的（2026-09-22）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条链路是什么
//
// ```text
// 点开一个片子
//   → get_detail      拿详情（简介、剧集、封面）
//   → get_sources     列可用播放源（多源换源的一级）
//   → get_episodes    按源拉剧集（多源换源的二级）
//   → resolve_stream  ★ 拿真实流地址（播放的最后一步）
//   → media_kit 播放
// ```
//
// # ★ 为什么 `resolve_stream` 特别重要
//
// 它是**唯一会改写流地址**的地方，而改写的原因是防盗链：
//
// ```text
// 外部视频站 CDN 实测：
//   无 UA            → 403
//   带 UA 无 Referer → 403
//   错误 Referer     → 403
//   正确 Referer+UA  → 206 ✓
// ```
// `<video>` 标签的请求头由浏览器决定，**JS 改不了** ——
// 所以必须把流地址换成**本地代理地址**，由代理带上正确的头转发。
//
// 这条逻辑放在这里而不是各个 provider 里，因为「取流」是所有源的
// 必经之路（与 `ensure_session` 同理）—— 放这里，新接入的源只要
// 按契约声明 `notWebReady` + `headers` 就自动获得此能力。

use std::sync::Arc;

use crate::model::{Episode, MediaDetail, MediaId, PlayRequest, PlaySource, StreamCandidate};
use crate::state::AppState;

/// 取媒体详情
///
/// 源：原版 `lib.rs` 的 `get_detail`
///
/// # ★ 封面也要走代理（原版注释记录的一个真 bug）
///
/// 「实测漏掉一处：只改了 `get_list` / `get_rank`，
///   详情页的封面还是裸 URL → 列表项能显示、点进去大图裂开。
///   这种『只修了一半』的 bug 很容易漏，因为列表页看起来已经好了。」
///
/// 所以这里必须调 `proxy_cover_one`。
pub async fn get_detail(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<MediaDetail, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    let mut d = p.detail(&mid).await.map_err(|e| {
        /*
         * ★★★ T4-C 附带（2026-10-31，lead addendum：csp-appget 静默失败必留痕）
         * cleanenv 审计实锤（.probe/play-audit-cleanenv-2026-10-31.md n=10）：
         * play_item cmd ok、日志零行、playing=false —— resolve 阶段的失败有
         * 1214799 补的 write_file_log，而 **detail 阶段**的失败（上游偶发断连）
         * 在 `map_err(|e| e.message)` 里无声消失 ⇒ 排障黑洞，与 resolve 同构。
         * 落盘口径与 resolve 完全同款：tag=PLAY、scrub_err_msg 脱敏、id 截 24 字符。
         */
        log_detail_failure(provider, id, &e);
        e.message
    })?;
    proxy_cover_one(state, provider, &mut d.cover).await;
    Ok(d)
}

/// detail 失败的落盘（与 [`resolve_stream`] 的 resolve 失败**同款口径**）
///
/// ```text
/// 抽成函数的原因：① get_detail 里内联会把成功路径的缩进搅乱；
/// ② 门禁可以直接喂 ProviderError 验证落盘行为（SOURIN_LOG_FILE 重定向），
///   不必为它起一个 AppState/registry（bootstrap 在测试进程会绑 8642）。
/// ```
fn log_detail_failure(provider: &str, id: &str, e: &crate::model::ProviderError) {
    let id_head: String = id.chars().take(24).collect();
    let msg = crate::applog::scrub_err_msg(&e.message);
    crate::applog::write_file_log(
        "PLAY",
        &format!(
            "detail 失败 provider={provider} id~={id_head} kind={:?} needs_login={} msg={msg}",
            e.kind, e.needs_login
        ),
    );
}

/// 列出可用播放源（多源换源的一级）
///
/// 源：原版 `lib.rs` 的 `get_sources`
pub async fn get_sources(
    state: &AppState,
    provider: &str,
    id: &str,
) -> Result<Vec<PlaySource>, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    p.sources(&mid).await.map_err(|e| e.message)
}

/// 按播放源拉取剧集（多源换源的二级）
///
/// 源：原版 `lib.rs` 的 `get_episodes`
///
/// # 参数名的坑
///
/// 原版前端传 `sourceCode`（camelCase），Rust 签名是 `source_code`。
/// `Args` 会自动兼容（见 `args.rs`）。
pub async fn get_episodes(
    state: &AppState,
    provider: &str,
    id: &str,
    source_code: &str,
) -> Result<Vec<Episode>, String> {
    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    p.episodes(&mid, source_code)
        .await
        .map_err(|e| e.message)
}

/// ★★★ 解析真实流地址 —— 播放链路的最后一步
///
/// 源：原版 `lib.rs` 的 `resolve_stream`
///
/// # 三件必须做的事（顺序都有讲究）
///
/// ```text
/// ① 取流前先确保会话可用（按需续期 → 必要时自动登录）
/// ② 拿到候选流后，把「需要自定义头」的流换成**本地代理地址**
/// ③ ★ 独立音轨（audio_url）也要走同一个代理
/// ```
///
/// ## ① 为什么会话检查放这里
///
/// 原版注释：「取流是所有源的必经之路 —— 在这里兜住，
/// 新接入的源只要覆盖 refresh_session/auto_login 就自动获得此能力。」
///
/// ## ② 为什么必须换代理（实测数据）
///
/// ```text
/// 无 UA            → 403
/// 带 UA 无 Referer → 403
/// 错误 Referer     → 403
/// 正确 Referer+UA  → 206 ✓
/// ```
/// CDN 只认 Referer，没有它一个字节都拿不到。
///
/// ## ③ ★ 音轨是最容易漏的（实测踩过）
///
/// DASH 分发时音视频分离，插件用 `audioUrl` 声明音频轨。
/// `<audio>` 和 `<video>` 一样改不了请求头 —— 音轨不注册代理的表现是：
///
/// ```text
/// 画面正常、但完全没有声音（而且不报错，只是静音）
/// ```
///
/// 这种「只坏一半」的问题最难查，所以在这里一并处理。
/// 音轨与视频轨来自同一个 CDN，防盗链要求完全一样，
/// 所以直接用同一个 headers 与 not_web_ready。
///
/// # 幂等性
///
/// `maybe_proxy` 内部会跳过已经是本地代理地址的 URL，
/// 所以重复调用不会把地址套娃（URL 越套越长）。
pub async fn resolve_stream(
    state: &AppState,
    provider: &str,
    id: &str,
    req: Option<PlayRequest>,
) -> Result<Vec<StreamCandidate>, String> {
    // ① 取流前先确保会话可用
    if let Some(false) = state.registry.ensure_session(provider).await {
        return Err("登录已失效，请到「设置 → 账号登录」重新登录".into());
    }

    let mid = MediaId::new(provider, id);
    let p = state
        .registry
        .route(&mid)
        .ok_or_else(|| format!("无法路由: {provider}:{id}"))?;
    let mut list = p
        .resolve(&mid, &req.unwrap_or_default())
        .await
        /*
         * ★ 2026-10-30（23018 猎捕二轮·观测黑洞，lead 授权修复）：resolve 阶段的
         *   失败此前**一行日志都不落盘** —— Dart 侧 catch 只进 `_error`
         *   （player_page.dart:5702 无 AppLog），而 [PLAY] 只在拿到流之后才写
         *   （player_page.dart:6350）⇒ 现场"连失败日志都没有"无法归因。
         *   ★ 落盘走 applog::write_file_log（tag=PLAY，对齐 Dart [PLAY] 惯例）：
         *     `log` 门面在本 crate 无 sink（streamproxy.rs:2179），log::warn 会被
         *     整个丢弃 —— 2026-10-30 真机已实锤过一次。
         *   脱敏口径（lead 指定）：只记 provider / 错误类别 / id 前缀（截 24 字符），
         *   **不含完整 URL 参数与 token**。
         */
        .map_err(|e| {
            let id_head: String = id.chars().take(24).collect();
            /*
             * ★★★ 2026-10-30（本批真机抽测暴露）：原来只记 `kind={:?}`（错误类别枚举），
             * 结果 67 条失败全是 `kind=Other` —— **真实原因一个字都没有**，
             * 等于白加了这条日志。排障必须看到 `e.message`。
             *
             * 脱敏口径（不变）：message 里可能带 URL/token，所以走 scrub_err_msg
             * 去掉 query 部分与长串凭据，只保留"人能看懂哪里错了"的那截。
             */
            let msg = crate::applog::scrub_err_msg(&e.message);
            crate::applog::write_file_log(
                "PLAY",
                &format!(
                    "resolve 失败 provider={provider} id~={id_head} kind={:?} needs_login={} msg={msg}",
                    e.kind, e.needs_login
                ),
            );
            e.message
        })?;

    /*
     * ★★★ task-8（2026-10-30）：resolve 出口先读一遍清单，把**真实整集时长**带进候选。
     * ```text
     * 真机取证：那条 dur=6 的清单实为 17 段 EXTINF 求和 82.72s + 2 个 DISCONTINUITY；
     * mpv 在不连续点重建时间轴 ⇒ stream.duration 报"当前分片时长"、pos 反复归零
     * ⇒ Owner 看到的「播放都是6秒」是时长读数错，不是内容短。
     * 硬约束（lead 定死）：①只有 ENDLIST（点播完结）才填 total，直播留 None；
     *   ②master 追一层子清单；③失败/超时留 None 不阻断起播；
     *   ④守卫 = kind==Hls 或 URL path 以 .m3u8 结尾（appyqk 把 master.m3u8
     *     错标成 Mp4 的实测教训：只认 kind 会漏）；⑤discontinuous 只作事实标记。
     *
     * ★ P9（2026-10-30 自查立案）：必须在循环**之前**一次批处理，不能按候选串行 await。
     *   实测串行代价（门禁 p9_batch_probe_wallclock_has_hard_cap，每条清单慢 1200ms）：
     *       8 条候选 = 9615ms / 32 条候选 = 38457ms  ⇒ 完全线性，且全堆在首帧之前，
     *   与 Owner 在 1.3 定的「不增加起播延迟」直接冲突。
     *   probe_candidates 内部并发（限流 8）+ 整批硬截止 2500ms；超截止的候选留 None。
     *
     * ⚠️ 必须在 maybe_proxy **之前**读 —— 用原始上游 URL 与候选自带头
     *   （Cookie/Referer/UA），本地代理地址读清单没有意义。
     * ```
     */
    crate::hls_facts::probe_candidates(&mut list).await;
    {
        let id_head: String = id.chars().take(24).collect();
        for c in &list {
            if c.playlist_total_ms.is_some() || c.playlist_discontinuous {
                // 拿到事实就落文件日志（排障用；什么都没读到就不写，避免刷屏）
                crate::applog::write_file_log(
                    "PLAY",
                    &format!(
                        "清单事实 id~={id_head} total_ms={:?} discontinuous={}",
                        c.playlist_total_ms, c.playlist_discontinuous
                    ),
                );
            }
        }
    }

    // ②③ 逐个候选流处理：流地址 + 独立音轨
    for c in &mut list {
        if let Some(local) =
            crate::streamproxy::maybe_proxy(&state.stream_proxy, &c.url, &c.headers, c.not_web_ready)
                .await
        {
            c.url = local;
        }

        // ★ 独立音轨也要走同一个代理（漏了就是"有画面没声音"）
        if let Some(audio) = c.audio_url.clone() {
            if let Some(local) = crate::streamproxy::maybe_proxy(
                &state.stream_proxy,
                &audio,
                &c.headers,
                c.not_web_ready,
            )
            .await
            {
                c.audio_url = Some(local);
            }
        }
    }

    Ok(list)
}

/// 给**单个**封面 URL 套代理（详情页用）
///
/// 源：原版 `lib.rs` 的 `proxy_cover_one`
///
/// # 与 `proxy_covers`（复数）的区别
///
/// ```text
/// proxy_covers   → 列表页，批量处理 items 里每个封面
/// proxy_cover_one→ 详情页，只有一个封面
/// ```
/// 两者的跳过条件与代理启动逻辑完全一致 ——
/// 这里抽成共用实现，避免「改了一个忘了另一个」。
pub async fn proxy_cover_one(state: &AppState, provider: &str, cover: &mut Option<String>) {
    let Some(c) = cover.as_ref() else { return };
    // 已经是本地代理地址 → 跳过（幂等）
    if c.starts_with("http://127.0.0.1:") {
        return;
    }
    let Some(m) = state.registry.manifests().into_iter().find(|m| m.id == provider) else {
        return;
    };
    if m.cover_headers.is_empty() {
        return;
    }
    if let Err(e) = state.stream_proxy.ensure_started().await {
        log::warn!("封面代理启动失败: {e}");
        return;
    }
    *cover = Some(
        state
            .stream_proxy
            .register_cover(c, m.cover_headers.clone()),
    );
}

/// 便利函数：解析并返回**第一个可播流**
///
/// # 为什么加这个（原版没有）
///
/// 原版前端要自己从 `Vec<StreamCandidate>` 里挑第一个能播的。
/// Flutter 侧同理会很啰嗦：
/// ```dart
/// final list = await SourinApi.resolveStream(...);
/// final playable = list.firstWhere((s) => !s.isDrm, orElse: () => ...);
/// ```
/// 但**这个挑选逻辑必须与原版一致**，否则可能选到 DRM 流导致黑屏。
///
/// ⚠️ 所以这里只做「跳过 DRM」这一条与源注释一致的过滤，
///    其余顺序完全保留（不排序、不按清晰度挑）——
///    排序是产品决策，不该由这一层偷偷决定。
pub async fn resolve_first_playable(
    state: &AppState,
    provider: &str,
    id: &str,
    req: Option<PlayRequest>,
) -> Result<Option<StreamCandidate>, String> {
    let list = resolve_stream(state, provider, id, req).await?;
    Ok(list.into_iter().find(|c| !c.drm_protected))
}

#[cfg(test)]
mod detail_failure_log_tests {
    use super::*;

    /// ★★★ T4-C 门禁（2026-10-31，lead addendum：csp-appget 静默失败必留痕）
    ///
    /// ```text
    /// 行为断言：log_detail_failure 必须把失败写进文件日志（SOURIN_LOG_FILE 覆盖
    ///   优先于测试进程守卫 —— applog::log_file_path 的第一分支，与
    ///   tests/file_log_gate.rs 同一套重定向手法）。
    /// 注入证红：把 log_detail_failure 里的 write_file_log 删掉 ⇒ 本条红。
    /// ```
    #[test]
    fn detail_failure_lands_in_file_log() {
        let dir = std::env::temp_dir().join(format!(
            "sourin-detail-log-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("建临时目录");
        let log = dir.join("sourin-test.log");
        std::env::set_var("SOURIN_LOG_FILE", &log);
        let e = crate::model::ProviderError::new(
            crate::model::ErrorKind::Network,
            "请求上游失败（https://up.example/api.php/getappapi.index/vodDetail）",
        );
        log_detail_failure("csp-appget-97d9adc9", "357566@轮播|0|https://x/y.m3u8", &e);
        std::env::remove_var("SOURIN_LOG_FILE");
        let body = std::fs::read_to_string(&log).expect("detail 失败必须落盘");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            body.contains("detail 失败 provider=csp-appget-97d9adc9"),
            "必须点明是 detail 阶段失败：{body}"
        );
        assert!(
            body.contains("id~=357566@轮播|0|https://x/y"),
            "id 截 24 字符：{body}"
        );
        assert!(
            body.contains("msg=请求上游失败"),
            "脱敏后原因必须可见：{body}"
        );
    }

    /// 接线断言：get_detail 的 map_err 必须真的调 log_detail_failure
    ///
    /// ```text
    /// ★ 只看 `#[cfg(test)]` **之前**的代码段 —— 不然本测试自己的注释里的调用串
    ///   也算命中（T4-C 实测抓到的假绿：注入删掉调用后断言仍绿）。
    /// 注入证红：把 get_detail map_err 里的 `log_detail_failure(provider, id, &e);`
    /// 删掉 ⇒ 本条红（源码级守卫，先例：tests/csp_episode_direct_play.rs）。
    /// ```
    #[test]
    fn get_detail_wires_detail_failure_logging() {
        let src = include_str!("playback.rs");
        let prod = src.split("#[cfg(test)]").next().unwrap_or("");
        assert!(
            prod.contains("log_detail_failure(provider, id, &e);"),
            "get_detail 的 detail 失败必须调 log_detail_failure（不许无声 map_err）"
        );
    }
}
