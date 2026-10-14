// ═══════════════════════════════════════════════════════════════════════
//  task-23 验收 —— 插件"记住链接 → 检测更新 → 更新 → 回滚"
// ═══════════════════════════════════════════════════════════════════════
//
// 用户拍板：
// > 通过链接检测更新,可以进行回滚
// > 插件市场暂时不做  github raw 暂时不做
//
// # ★ 为什么必须起**本地 HTTP 服务**（而不是用外网 URL）
//
// ```text
// ① 外网依赖不可控（CDN 抽风、限流、离线跑不了）→ 验收会变成"看运气"
// ② 要验的是"**远端内容变了** → 检测出更新"，必须能**改远端**
//    —— 外网 URL 我改不了，本地服务随时能改
// ③ 回滚要"连续多档"，需要造多个版本 —— 本地服务一个变量就够
// ```
// 用 `tokio::net::TcpListener` 手写最小 HTTP/1.1（不引新依赖）：
// 只处理 `GET`，固定返回一段可变 JS。
//
// # 覆盖的验收点
//
// ```text
// ① 端到端：安装 → 检测(无更新) → 改远端版本 → 检测(有更新)
//           → 更新 → 版本变新 → 回滚 → 版本回旧
// ② 版本比较：1.10.0 > 1.9.0 真、1.2.3 > 1.2.10 假
// ③ ★ 无来源插件：needs_source=true，**不许假装能检测**
// ④ 回滚连续多档 + .versions 清理
// ⑤ ★ 回滚/更新**不碰** plugins/.data/（用户配置）
// ⑥ 批量检测：只有有链接的被查，无链接的如实跳过
// ⑦ 老数据：26 个无 meta 的插件不报错
// ```

use sourin_core::commands_provider as cp;
use sourin_core::plugins;
use sourin_core::state::AppState;
use std::sync::Arc;

// ─────────────────────────── 隔离环境 ───────────────────────────

/// 全新隔离数据目录（**绝不碰用户的真实目录**）
async fn fresh(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t23-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 往隔离目录里放一个"手动安装"的插件（**没有 meta** = 本机 26 个的真实状态）
fn put_manual_plugin(st: &AppState, id: &str, version: &str) -> String {
    let dir = sourin_core::state::plugins_dir(&st.data_dir);
    std::fs::create_dir_all(&dir).unwrap();
    let src = format!(
        "/** @id {id} @name 测试{id} @version {version} */\n\
         globalThis.plugin = {{ capabilities: {{ vod: true }} }};\n"
    );
    let file = format!("{id}.js");
    std::fs::write(dir.join(&file), src).unwrap();
    file
}

// ─────────────────────────── 最小 HTTP 服务 ───────────────────────────

/// 一个能**随时改内容**的本地 HTTP 服务
///
/// 返回 `(url, 内容句柄)`。测试改句柄里的字符串 = 改"远端"内容。
struct LocalServer {
    url: String,
    body: Arc<tokio::sync::RwLock<String>>,
}

impl LocalServer {
    /// 起服务；`initial` 是初始内容
    async fn start(initial: &str) -> LocalServer {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let body = Arc::new(tokio::sync::RwLock::new(initial.to_string()));
        let b2 = body.clone();

        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                let b = b2.clone();
                tokio::spawn(async move {
                    // 读掉请求头（不解析 —— 我们只会被 GET 一个固定路径）
                    let mut buf = [0u8; 2048];
                    let _ = sock.read(&mut buf).await;
                    let payload = b.read().await.clone();
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\n\
                         Content-Type: application/javascript; charset=utf-8\r\n\
                         Content-Length: {}\r\n\
                         Connection: close\r\n\r\n{}",
                        payload.len(),
                        payload
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.flush().await;
                });
            }
        });

        LocalServer {
            url: format!("http://{addr}/plugin.js"),
            body,
        }
    }

    /// 改"远端"内容（模拟作者发新版）
    async fn set(&self, content: &str) {
        *self.body.write().await = content.to_string();
    }
}

/// 造一个合法的插件源码
fn plugin_src(id: &str, version: &str, extra: &str) -> String {
    format!(
        "/** @id {id} @name 远程{id} @version {version} */\n\
         globalThis.plugin = {{ capabilities: {{ vod: true }} }};\n\
         {extra}\n"
    )
}

// ═══════════════════════ ① 端到端全流程 ═══════════════════════

/// ★★ 主验收：安装 → 检测 → 远端发新版 → 检测 → 更新 → 回滚
#[tokio::test]
async fn e2e_install_check_update_rollback() {
    let st = fresh("e2e").await;
    let srv = LocalServer::start(&plugin_src("e2ep", "1.0.0", "// v1")).await;

    // ── 安装（走真实 install_plugin：下载 + 校验 + 落盘 + 记来源）──
    let r = sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .expect("安装应成功");
    assert_eq!(r["id"], "e2ep");
    assert_eq!(r["version"], "1.0.0");
    println!("[1] 安装成功 id={} v={}", r["id"], r["version"]);

    // ★ 安装来源必须**落盘**（这是本任务补的那个缺口）
    let meta = plugins::read_plugin_meta(&sourin_core::state::plugins_dir(&st.data_dir), "e2ep")
        .expect("install_plugin 必须写 meta（否则检测更新无从下手）");
    assert_eq!(meta.source_url.as_deref(), Some(srv.url.as_str()));
    assert_eq!(meta.installed_version, "1.0.0");
    println!("[2] 来源已落盘 sourceUrl={:?}", meta.source_url);

    // ── 检测（无更新）──
    let c = cp::check_plugin_update(&st, "e2ep").await.unwrap();
    assert!(!c.needs_source, "有链接就不该标 needs_source");
    assert!(!c.has_update, "刚装完不该有更新");
    assert_eq!(c.remote_version.as_deref(), Some("1.0.0"));
    assert!(c.same_content, "内容一模一样应判 same_content");
    assert!(c.error.is_none());
    println!("[3] 检测：无更新（remote={:?}）", c.remote_version);

    // ── 远端发新版 ──
    srv.set(&plugin_src("e2ep", "2.0.0", "// v2 new feature")).await;

    let c = cp::check_plugin_update(&st, "e2ep").await.unwrap();
    assert!(c.has_update, "远端 2.0.0 > 本地 1.0.0 → 应检出更新");
    assert_eq!(c.remote_version.as_deref(), Some("2.0.0"));
    assert!(!c.same_content, "内容变了");
    println!("[4] 检测：有更新 → v{}", c.remote_version.unwrap());

    // ── 更新 ──
    let up = cp::update_plugin_from_source(&st, "e2ep").await.unwrap();
    assert_eq!(up["updated"], true);
    assert_eq!(up["fromVersion"], "1.0.0");
    assert_eq!(up["version"], "2.0.0");
    println!("[5] 更新成功 v{} → v{}", up["fromVersion"], up["version"]);

    // 磁盘上真的是新内容
    let on_disk = std::fs::read_to_string(sourin_core::state::plugins_dir(&st.data_dir).join("e2ep.js")).unwrap();
    assert!(on_disk.contains("2.0.0"), "磁盘上应是新版");
    assert!(on_disk.contains("new feature"));

    // ★ 旧版必须被归档（回滚的数据来源）
    let hist = plugins::list_plugin_versions(&sourin_core::state::plugins_dir(&st.data_dir), "e2ep");
    assert_eq!(hist.len(), 1, "更新前应归档旧版一档");
    assert_eq!(hist[0].0, "1.0.0");
    println!("[6] 旧版已归档：{:?}", hist[0].0);

    // ── 回滚 ──
    let rb = cp::rollback_plugin(&st, "e2ep", "1.0.0").await.unwrap();
    assert_eq!(rb["rolledBack"], true);
    assert_eq!(rb["fromVersion"], "2.0.0");
    assert_eq!(rb["version"], "1.0.0");
    println!("[7] 回滚成功 v{} → v{}", rb["fromVersion"], rb["version"]);

    let on_disk = std::fs::read_to_string(sourin_core::state::plugins_dir(&st.data_dir).join("e2ep.js")).unwrap();
    assert!(on_disk.contains("1.0.0"), "回滚后磁盘上应是旧版");
    assert!(!on_disk.contains("new feature"), "新版内容必须消失");

    // ★ 对称性：回滚也要把"被换掉的 2.0.0"归档，否则手滑回滚就回不去了
    let hist = plugins::list_plugin_versions(&sourin_core::state::plugins_dir(&st.data_dir), "e2ep");
    assert!(
        hist.iter().any(|(v, _)| v == "2.0.0"),
        "回滚应把当前版(2.0.0)也归档，让用户能再回来；实际={:?}",
        hist.iter().map(|(v, _)| v).collect::<Vec<_>>()
    );
    println!(
        "[8] 回滚后历史档：{:?}",
        hist.iter().map(|(v, _)| v).collect::<Vec<_>>()
    );

    // 回滚后 meta 的版本要跟着改（但**来源链接保留** —— 否则回滚一次就再也不能检测了）
    let meta = plugins::read_plugin_meta(&sourin_core::state::plugins_dir(&st.data_dir), "e2ep").unwrap();
    assert_eq!(meta.installed_version, "1.0.0");
    assert_eq!(
        meta.source_url.as_deref(),
        Some(srv.url.as_str()),
        "回滚不该让插件失去安装来源"
    );
    println!("[9] 回滚后来源仍在：{:?}", meta.source_url);
}

// ═══════════════════════ ② 版本比较（验收明确要求）═══════════════════════

#[tokio::test]
async fn version_compare_required_cases() {
    // ★ 验收原话：`1.10.0 > 1.9.0` 为真、`1.2.3 > 1.2.10` 为假
    assert!(plugins::version_is_newer("1.10.0", "1.9.0"), "1.10.0 > 1.9.0");
    assert!(!plugins::version_is_newer("1.2.3", "1.2.10"), "1.2.3 不大于 1.2.10");
    // ★ 反证：字符串比较会把这两条都判反
    assert!("1.10.0" < "1.9.0", "（说明：字符串比较确实会判错，所以必须按数字段）");
    assert!("1.2.3" > "1.2.10", "（说明：字符串比较确实会判错）");
    println!("[版本比较] 1.10.0>1.9.0 ✓  1.2.3>1.2.10 假 ✓（字符串比较两条都错）");
}

// ═══════════════════════ ③ ★ 无来源插件不许假装能检测 ═══════════════════════

#[tokio::test]
async fn manual_plugin_reports_needs_source_not_up_to_date() {
    let st = fresh("nosrc").await;
    put_manual_plugin(&st, "manual1", "1.0.0");
    cp::reload_plugins(&st).await.unwrap();

    let c = cp::check_plugin_update(&st, "manual1").await.unwrap();

    // ★★ 这是本任务最重要的产品原则
    assert!(
        c.needs_source,
        "手动放入的插件必须如实报 needs_source（没有链接可查）"
    );
    assert!(
        c.source_url.is_none(),
        "没有来源就不能编一个出来"
    );
    assert!(
        !c.has_update,
        "查都没查过，绝不能报「有更新」"
    );
    assert!(
        c.source_url.is_none(),
        "★ 界面靠「有没有 source_url」决定**不显示**「检测更新」按钮"
    );
    // ★ 它**不是**错误 —— "没有来源"是完全正常的状态
    assert!(c.error.is_none(), "没有来源不是错误，不该报错");

    // 更新命令也要明确拒绝（而不是"假装成功"）
    let e = cp::update_plugin_from_source(&st, "manual1").await;
    assert!(e.is_err(), "无来源插件不能更新");
    let msg = e.unwrap_err();
    assert!(
        msg.contains("没有安装链接"),
        "错误信息要如实说明原因；实际={msg}"
    );
    println!("[无来源] needs_source=true, can_check=false, 更新被拒: {msg}");
}

/// ★ 从链接安装的新插件**必须**有检测能力（否则功能做完界面上什么都看不到）
#[tokio::test]
async fn linked_plugin_gets_check_capability() {
    let st = fresh("linked").await;
    let srv = LocalServer::start(&plugin_src("linked1", "3.1.0", "// x")).await;
    sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .unwrap();

    let c = cp::check_plugin_update(&st, "linked1").await.unwrap();
    assert!(!c.needs_source);
    assert!(c.source_url.is_some() && !c.needs_source, "★ 从链接安装的插件必须能检测更新");
    assert!(c.error.is_none(), "而且检测应成功完成（无错误）");
    assert_eq!(c.version, "3.1.0");
    println!("[有来源] 有 source_url（界面会显示「检测更新」按钮）");
}

// ═══════════════════════ ④ 回滚连续多档 + 清理 ═══════════════════════

#[tokio::test]
async fn rollback_multiple_versions_and_prune() {
    let st = fresh("multi").await;
    // 直接放一个 1.0.0，然后连升 6 次 → 产生 6 档历史（超过上限 5）
    put_manual_plugin(&st, "multi1", "1.0.0");
    cp::reload_plugins(&st).await.unwrap();

    let srv = LocalServer::start(&plugin_src("multi1", "1.0.0", "// v1")).await;
    cp::set_plugin_source(&st, "multi1", &srv.url).unwrap();

    for v in ["1.1.0", "1.2.0", "1.9.0", "1.10.0", "1.11.0", "2.0.0"] {
        srv.set(&plugin_src("multi1", v, &format!("// {v}"))).await;
        let r = cp::update_plugin_from_source(&st, "multi1").await.unwrap();
        assert_eq!(r["version"], v, "应更新到 {v}");
    }

    let dir = sourin_core::state::plugins_dir(&st.data_dir);
    let hist: Vec<String> = plugins::list_plugin_versions(&dir, "multi1")
        .into_iter()
        .map(|(v, _)| v)
        .collect();
    // ★ 清理策略：只留最近 MAX_PLUGIN_VERSIONS(5) 档
    assert_eq!(
        hist.len(),
        plugins::MAX_PLUGIN_VERSIONS,
        "历史档应被清理到上限；实际={hist:?}"
    );
    /*
     * ★★ `2.0.0` **不在**历史里 —— 这是**对的**，不是 bug（实测踩到过判断错误）
     *
     * `.versions/` 存的是**历史档**（"以前的版本"），
     * **当前**版本永远在 `plugins/multi1.js` 里。
     * 所以连升到 2.0.0 之后：
     * ```text
     * plugins/multi1.js          = 2.0.0     ← 当前（不在历史里）
     * .versions/                 = 1.11.0 1.10.0 1.9.0 1.2.0 1.1.0  ← 5 档历史
     *                              （1.0.0 是最旧的一档，被清理掉了）
     * ```
     * 我第一版断言写成 `["2.0.0", "1.11.0", ...]` —— 把当前版本当成历史档，
     * 是**测试期望写错**。回滚列表本来就该只列"可以回退到的版本"。
     *
     * ⚠️ 顺序必须是**版本序**而不是文件名字符串序：
     *    `1.10.0` 要排在 `1.9.0` **前面**（字符串序会反过来）。
     */
    assert_eq!(
        hist,
        vec!["1.11.0", "1.10.0", "1.9.0", "1.2.0", "1.1.0"],
        "历史档应=最近 5 个**历史**版本（当前版 2.0.0 不在其中）"
    );
    println!("[多档] 连升 6 次后历史档（已清理到 5，当前版 2.0.0 在 plugins/ 不在历史里）：{hist:?}");

    // 回滚到**较老的一档**（不是上一档）—— 验证"能连续回多档"
    let rb = cp::rollback_plugin(&st, "multi1", "1.9.0").await.unwrap();
    assert_eq!(rb["version"], "1.9.0");
    let on_disk = std::fs::read_to_string(dir.join("multi1.js")).unwrap();
    assert!(on_disk.contains("1.9.0"));
    println!("[多档] 直接从 2.0.0 回滚到 1.9.0（跳过中间档）✓");

    // 回滚一个不存在的档 → 必须报错并**列出可用档**（方便用户纠正）
    let e = cp::rollback_plugin(&st, "multi1", "9.9.9").await.unwrap_err();
    assert!(e.contains("9.9.9") && e.contains("可用版本"), "错误要列可用档：{e}");
    println!("[多档] 回滚不存在的档被拒且列出可用项 ✓");
}

// ═══════════════════════ ⑤ ★ 不碰用户配置 ═══════════════════════

/// ★★ 更新 / 回滚**绝不能碰** `plugins/.data/`（插件配置 = 用户数据）
///
/// 这条是 Lead 明确要求加测试的：回滚只换 `.js`，用户配置必须原样保留。
#[tokio::test]
async fn update_and_rollback_keep_user_config() {
    let st = fresh("cfg").await;
    let srv = LocalServer::start(&plugin_src("cfg1", "1.0.0", "// v1")).await;
    sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .unwrap();

    // 写一份"用户配置"（插件的私有存储）
    let data_dir = sourin_core::state::plugins_dir(&st.data_dir).join(".data");
    std::fs::create_dir_all(&data_dir).unwrap();
    let cfg_path = data_dir.join("cfg1.json");
    let cfg = r#"{"token":"user-secret","quality":"1080p"}"#;
    std::fs::write(&cfg_path, cfg).unwrap();

    // 更新
    srv.set(&plugin_src("cfg1", "2.0.0", "// v2")).await;
    cp::update_plugin_from_source(&st, "cfg1").await.unwrap();
    assert_eq!(
        std::fs::read_to_string(&cfg_path).unwrap(),
        cfg,
        "★ 更新不能碰 plugins/.data/（用户配置）"
    );

    // 回滚
    cp::rollback_plugin(&st, "cfg1", "1.0.0").await.unwrap();
    assert_eq!(
        std::fs::read_to_string(&cfg_path).unwrap(),
        cfg,
        "★ 回滚不能碰 plugins/.data/（用户配置）"
    );
    println!("[用户配置] 更新 + 回滚后 .data/cfg1.json 逐字节未变 ✓");
}

// ═══════════════════════ ⑥ 批量检测 ═══════════════════════

/// ★ 批量：**只有有链接的被查**，无链接的如实跳过（Lead 要求覆盖）
#[tokio::test]
async fn batch_check_only_queries_linked_plugins() {
    let st = fresh("batch").await;

    // 2 个手动插件（无链接）
    put_manual_plugin(&st, "man_a", "1.0.0");
    put_manual_plugin(&st, "man_b", "1.0.0");
    // 1 个从链接装的 + 远端已发新版
    let srv = LocalServer::start(&plugin_src("link_c", "1.0.0", "// v1")).await;
    sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .unwrap();
    srv.set(&plugin_src("link_c", "2.0.0", "// v2")).await;
    cp::reload_plugins(&st).await.unwrap();

    let r = cp::check_all_plugin_updates(&st).await.unwrap();
    let items = r["items"].as_array().unwrap();
    let skipped = r["skipped"].as_u64().unwrap();

    println!("[批量] items={} skipped={}", items.len(), skipped);
    for it in items {
        println!(
            "   {} needsSource={} hasUpdate={} remote={:?}",
            it["id"], it["needs_source"], it["has_update"], it["remote_version"]
        );
    }

    /*
     * ★ 断言"按 id 找得到我放的 3 个"，而不是"总数 == 3"。
     *
     * 实测踩到：`AppState::bootstrap` 会 `seed_demo_plugin()` ——
     * 首次启动往 plugins/ 释放一个 `demo.js`（默认停用）。
     * 所以隔离目录里其实有 **4** 个插件，总数断言直接红。
     *
     * ⚠️ 这是**测试的期望写错了**，不是产品 bug：demo 是随程序发布的示例插件，
     *    它当然也该出现在批量检测里（而且它没有来源 → 计入 skipped）。
     *    写"总数相等"这种断言很脆 —— 上游多播种一个插件就假红。
     *    改成"逐个 id 找得到 + 属性正确"，才是真正要守的东西。
     */
    for want in ["man_a", "man_b", "link_c"] {
        assert!(
            items.iter().any(|i| i["id"] == want),
            "{want} 应出现在批量结果里；实际={:?}",
            items.iter().map(|i| i["id"].clone()).collect::<Vec<_>>()
        );
    }

    // ★ skipped = 无链接的（含 bootstrap 播种的 demo.js）
    let no_src = items.iter().filter(|i| i["needs_source"] == true).count();
    assert_eq!(
        skipped as usize, no_src,
        "skipped 应等于「无来源」的个数（界面要如实说有多少个查不了）"
    );
    assert!(skipped >= 2, "至少 man_a / man_b 两个无来源；实际={skipped}");
    println!("[批量] 无来源 {skipped} 个（含 bootstrap 播种的 demo.js）");

    let link = items.iter().find(|i| i["id"] == "link_c").unwrap();
    assert_eq!(link["needs_source"], false);
    assert_eq!(link["has_update"], true, "远端 2.0.0 > 本地 1.0.0");

    let man = items.iter().find(|i| i["id"] == "man_a").unwrap();
    assert_eq!(man["needs_source"], true, "手动插件必须如实标 needs_source");
    assert_eq!(man["has_update"], false, "没查过就不能说「有更新」");
}

// ═══════════════════════ ⑦ 老数据兼容 ═══════════════════════

/// ★ 已装 26 个**没有 meta** 的插件（本机真实状态）→ 不报错，如实标记
#[tokio::test]
async fn legacy_plugins_without_meta_are_tolerated() {
    let st = fresh("legacy").await;
    for i in 0..5 {
        put_manual_plugin(&st, &format!("legacy{i}"), "1.0.0");
    }
    cp::reload_plugins(&st).await.unwrap();

    // 每个都不该报错
    for i in 0..5 {
        let id = format!("legacy{i}");
        let c = cp::check_plugin_update(&st, &id)
            .await
            .unwrap_or_else(|e| panic!("老数据不该报错（{id}）: {e}"));
        assert!(c.needs_source, "{id} 没有 meta → needs_source");
        assert_eq!(c.version, "1.0.0");
    }
    println!("[老数据] 5 个无 meta 插件全部如实返回 needs_source，无报错 ✓");

    // 也能优雅地补上来源（真实功能：用户说"我这个其实来自这个链接"）
    let srv = LocalServer::start(&plugin_src("legacy0", "1.5.0", "// x")).await;
    cp::set_plugin_source(&st, "legacy0", &srv.url).unwrap();
    let c = cp::check_plugin_update(&st, "legacy0").await.unwrap();
    assert!(!c.needs_source, "补上来源后就能检测了");
    assert!(c.has_update, "远端 1.5.0 > 本地 1.0.0");
    println!("[老数据] 补来源后立刻可检测，并检出 1.5.0 ✓");
}

// ═══════════════════════ ⑧ 失败要如实 ═══════════════════════

/// 链接失效 / 返回不是 JS → **如实报错**，不许静默成"已是最新"
#[tokio::test]
async fn broken_link_reports_error_not_up_to_date() {
    let st = fresh("broken").await;
    put_manual_plugin(&st, "broken1", "1.0.0");
    cp::reload_plugins(&st).await.unwrap();

    // 指向一个必然连不上的端口
    cp::set_plugin_source(&st, "broken1", "http://127.0.0.1:9/none.js")
        .unwrap();

    let c = cp::check_plugin_update(&st, "broken1").await.unwrap();
    assert!(!c.needs_source, "它**有**链接（只是连不上）");
    assert!(!c.has_update, "查失败不能说有更新");
    assert!(
        c.error.is_some(),
        "★ 查失败必须如实报错 —— 绝不能静默成「已是最新」（那是假装成功）"
    );
    assert!(c.error.is_some(), "界面靠 error 区分「查到结论」和「查失败」");
    println!("[失败如实] error={:?}", c.error.unwrap());

    // 远端返回的不是插件（缺 @id）→ 也要如实报错
    let srv = LocalServer::start("<html>404 not found</html>").await;
    cp::set_plugin_source(&st, "broken1", &srv.url).unwrap();
    let c = cp::check_plugin_update(&st, "broken1").await.unwrap();
    assert!(c.error.is_some(), "返回 HTML 不是插件 → 必须报错");
    println!("[失败如实] 返回非插件 error={:?}", c.error.unwrap());
}

/// ★ 更新时若链接指向**别的插件**（@id 不一致）必须拒绝
///
/// 理由：`source_url` 是**外部可变**的 —— 站点被劫持或作者换了仓库，
/// 都可能让"更新"变成"用一个完全不同的插件替换掉用户现在这个"。
#[tokio::test]
async fn update_rejects_id_mismatch() {
    let st = fresh("mismatch").await;
    let srv = LocalServer::start(&plugin_src("orig_id", "1.0.0", "// v1")).await;
    sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .unwrap();

    // 远端被换成了另一个插件
    srv.set(&plugin_src("different_id", "9.9.9", "// evil")).await;

    let e = cp::update_plugin_from_source(&st, "orig_id").await.unwrap_err();
    assert!(e.contains("不一致"), "必须拒绝 @id 不一致的更新；实际={e}");

    // 本地文件必须**没被改**
    let on_disk = std::fs::read_to_string(sourin_core::state::plugins_dir(&st.data_dir).join("orig_id.js")).unwrap();
    assert!(on_disk.contains("1.0.0") && !on_disk.contains("evil"));
    println!("[防替换] @id 不一致被拒且本地未改 ✓");
}

/// 内容没变（版本号也没变）→ `updated=false`，**不产生新历史档**
#[tokio::test]
async fn identical_content_is_not_overwritten() {
    let st = fresh("same").await;
    let src = plugin_src("same1", "1.0.0", "// fixed");
    let srv = LocalServer::start(&src).await;
    sourin_core::commands_remote::install_plugin(&st, &srv.url)
        .await
        .unwrap();

    // 原样再"更新"一次
    let r = cp::update_plugin_from_source(&st, "same1").await.unwrap();
    assert_eq!(r["updated"], false, "内容一致就不该覆盖");
    assert!(r["reason"].as_str().unwrap().contains("一致"));
    assert!(
        plugins::list_plugin_versions(&sourin_core::state::plugins_dir(&st.data_dir), "same1").is_empty(),
        "没真的更新就不该产生历史档（否则 .versions 会被无意义的档撑满）"
    );
    println!("[内容一致] updated=false 且未产生历史档 ✓");
}
