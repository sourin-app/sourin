//! ★ 宿主级验收：真 QuickJS 加载用户目录的插件
//!
//! 补的是 `sec-kit` 明确说"做不到"的那一环：
//!   他的 harness 跑在 Node/V8，**不等于** QuickJS 能跑。
//!
//! 两条路径：
//!   ① `parse_meta`  —— 纯文本解析（宿主识别插件的第一步）
//!   ② `hydrate_capabilities` —— **真在 QuickJS 里执行脚本**读能力位
//!      （这是"能不能真的跑起来"的唯一证据）

use sourin_core::provider::MediaProvider;
use std::path::PathBuf;

/// 要验的插件文件名（默认取环境变量 SOURIN_PROBE_PLUGIN，避免在仓库里点名具体网站）
fn probe_file() -> String {
    std::env::var("SOURIN_PROBE_PLUGIN").unwrap_or_else(|_| "demo.js".to_string())
}

fn plugins_dir() -> PathBuf {
    let appdata = std::env::var("APPDATA").unwrap_or_default();
    PathBuf::from(appdata).join("app.sourin.player").join("plugins")
}

#[test]
fn host_parses_the_plugin_meta() {
    let f = plugins_dir().join(probe_file());
    if !f.exists() { eprintln!("跳过：{} 不存在", f.display()); return; }
    let src = std::fs::read_to_string(&f).expect("读插件");
    let meta = sourin_core::plugins::parse_meta(&src);
    eprintln!("★ parse_meta: id={} name={} version={}", meta.id, meta.name, meta.version);
    assert!(!meta.id.is_empty(), "id 不能为空");
    assert!(!meta.name.is_empty(), "name 不能为空");
}

#[tokio::test]
async fn host_executes_the_plugin_in_quickjs() {
    let dir = plugins_dir();
    let f = dir.join(probe_file());
    if !f.exists() { eprintln!("跳过：{} 不存在", f.display()); return; }
    let src = std::fs::read_to_string(&f).expect("读插件");
    let mut p = sourin_core::plugins::JsPluginProvider::from_source(&src)
        .expect("from_source 失败（语法错误？）");
    p = p.with_data_dir(dir.clone());

    // ★ 这一步**真的在 QuickJS 里执行脚本**（eval + 读 capabilities）
    p.hydrate_capabilities().await;

    let caps = &p.manifest().capabilities;
    eprintln!("★ QuickJS 执行成功，能力位：");
    eprintln!("  vod        = {}", caps.vod);
    eprintln!("  search     = {}", caps.search);
    eprintln!("  live       = {}", caps.live);
    eprintln!("  danmaku    = {}", caps.danmaku);
    assert!(caps.search, "★ 搜索能力必须为 true（否则脚本没被正确执行）");
    assert!(caps.vod, "★ vod 能力必须为 true");
}

#[test]
fn host_loads_all_user_plugins() {
    let dir = plugins_dir();
    if !dir.exists() { eprintln!("跳过：{} 不存在", dir.display()); return; }
    let (ok, bad) = sourin_core::plugins::load_plugins(&dir);
    eprintln!("★ 用户目录插件：成功 {} 个，失败 {} 个", ok.len(), bad.len());
    for (name, err) in &bad {
        eprintln!("  FAIL {} ⇒ {}", name, err);
    }
    let probe_bad = bad.iter().find(|(n, _)| n == "PLUGIN_FILE");
    assert!(probe_bad.is_none(), "PLUGIN_FILE 加载失败: {probe_bad:?}");
}