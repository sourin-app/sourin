// ═══════════════════════════════════════════════════════════════════════
//  task-38 证据：**用户实际部署的那份** srca.js 的能力探测
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独测"部署版"
//
// 实测发现：`canAutoLogin: true` 这个**声明**只存在于仓库副本里
// （`rust/sourin_core/plugins/srca.js`），而运行时加载的是
// **用户目录那份**（`%APPDATA%\...\plugins\srca.js`）——
// 它**没有**那行声明（`srca.js` 从来不由程序投放，见 state.rs:707）。
//
// ⇒ 所以"声明式能力位"对真实用户**取不到值**。
//
// ★ 这个探针验证：**运行时方法** `canAutoLogin()` 在**部署版**上是否为 true。
//   若为 true ⇒ 说明"直接问插件"（而不是"等它声明"）能立刻拿到正确答案，
//   这为"声明 或 探测"那个方案提供依据。

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;

mod support;
use support::t38_fixture::T38Fixture;

#[tokio::test]
async fn deployed_srca_reports_can_auto_login_at_runtime() {
    let fixture = T38Fixture::from_env().expect("select explicit T38 fixture");
    let dep = fixture
        .read_deployed_source()
        .expect("read plugins/srca.js fixture");
    let repo = fixture
        .read_reference_source()
        .expect("read reference/srca.js fixture");

    println!("\n=========== 部署版 vs 仓库版 ===========");
    println!("部署版 字节 = {}", dep.len());
    println!("仓库版 字节 = {}", repo.len());
    println!(
        "部署版有 `canAutoLogin: true` 声明 = {}",
        dep.contains("canAutoLogin: true")
    );
    println!(
        "仓库版有 `canAutoLogin: true` 声明 = {}",
        repo.contains("canAutoLogin: true")
    );
    println!(
        "部署版实现了 `canAutoLogin()` 方法 = {}",
        dep.contains("async canAutoLogin()")
    );

    // ── 关键：部署版的**运行时探测**结果 ──
    //   插件只读写显式 store 的独占临时副本。
    let workspace = fixture
        .copy_store("deployed-data")
        .expect("copy explicit store fixture");
    let data = workspace.path().to_path_buf();

    let mut p_dep = JsPluginProvider::from_source(&dep)
        .expect("解析部署版")
        .with_data_dir(data.clone());
    p_dep.hydrate_capabilities().await;

    let declared = p_dep.manifest().capabilities.can_auto_login;
    let runtime = p_dep.can_auto_login().await;

    println!("\n=========== 部署版的能力值 ===========");
    println!("声明式 can_auto_login = {declared}   ← 来自 capabilities");
    println!("运行时 can_auto_login() = {runtime}  ← 直接问插件");

    // ── 断言：部署版的**运行时探测**必须为 true ──
    assert!(
        runtime,
        "★★★ 部署版 srca.js 实现了 canAutoLogin() 且 store 里有凭据 —— \
         运行时探测必须是 true。若为 false，说明凭据不在/插件坏了"
    );

    /*
     * ★★ 记录"声明式取不到值"这个事实（**不**断言它必须为 false ——
     *    那样在仓库版被投放后会假红）。
     *    这里只是把两者的差异打印出来，作为"要不要改成运行时探测"的依据。
     */
    if !declared && runtime {
        println!(
            "\n★★★ 结论：部署版 **声明式取不到值（false）但运行时为 true**\n\
             ⇒ 只靠声明，用户永远看不到「正在自动重新登录」\n\
             ⇒ 「运行时探测」能立刻拿到正确答案"
        );
    }

    // ── 阳性对照：把凭据删掉 → 运行时也必须变 false ──
    let workspace2 = fixture
        .copy_store("deployed-nocred")
        .expect("copy explicit store fixture");
    let data2 = workspace2.path().to_path_buf();
    let raw = std::fs::read_to_string(data2.join("srca.json")).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    v.as_object_mut().unwrap().remove("credentials");
    std::fs::write(
        data2.join("srca.json"),
        serde_json::to_string_pretty(&v).unwrap(),
    )
    .unwrap();

    let mut p2 = JsPluginProvider::from_source(&dep)
        .unwrap()
        .with_data_dir(data2);
    p2.hydrate_capabilities().await;
    let runtime2 = p2.can_auto_login().await;
    println!("\n阳性对照（删掉 credentials）: can_auto_login() = {runtime2}");
    assert!(
        !runtime2,
        "★ 没有凭据时运行时探测必须是 false（否则「能不能自动重登」这个判据是坏的）"
    );
}
