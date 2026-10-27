// ═══════════════════════════════════════════════════════════════════════
//  R3-D 落地核验：改后注册表 == 改前写死的那 5 个类（行为零变化）
// ═══════════════════════════════════════════════════════════════════════
//
// 跑法：cargo test --test zz_r3_csp_registry -- --nocapture
//
// # 这个文件守什么
// ```text
// ① 改动前后**注册表内容逐字相同**（5 个类；FirstAid 仍不在 —— 它"已实现但未通电"）。
// ② 新增类**不需要改 build_registry** —— 判据：源码里 `m.insert(` 为 0 处，
//    且自注册只出现在类自己的文件里。
// ③ 同名冲突**显式报错**（注入验证）。
// ④ 未注册类逐字仍报 `csp_X 尚未实现`。
// ⑤ 类实现文件里 grep 不到宿主细节（解耦约束）。
// ```
use std::collections::BTreeSet;

use regex::Regex;

use sourin_core::csp::{self, CspSite};

/// 改前 `build_registry()` 里写死的那一份（照抄，作为**行为零变化**的基准）
///
/// # ★★ 2026-10-27 R3 增量批次：判据从「等号」改成「**包含式**」
/// ```text
/// 本条原先写的是 `assert_eq!(after, before)` + `assert_eq!(len(), 5)`
/// ⇒ 在**增量批次**里不成立：R3 批要补 60+ 个类，
///   "注册表里多了一个类"是**预期行为**，不是"误接了未通电的类"。
///   （当时它红过：csp-batch-b 一注册自己的类，len() 立刻 ≠ 5。）
///
/// 但它真正要守的东西**一条都没丢**：
///   · 既有 5 个类**一个都不许少**（少了 = 既有源静默失效）
///   · `FirstAid` **仍不许**被注册（"已实现但未通电"这条边界不许被顺手推倒）
/// ⇒ 改法是**只放宽"多"，不放宽"少"和"FirstAid"**。
/// ```
const BEFORE_HARDCODED: &[&str] = &["4KZhinan", "App99", "Bili", "Ikanbot", "PanWebShare"];

#[test]
fn r3_registry_contains_all_original_hardcoded_classes() {
    let after: BTreeSet<&str> = csp::implemented_classes().into_iter().collect();
    // ① 既有 5 类**一个都不许少**（这是本条的核心：不许静默失效）
    for c in BEFORE_HARDCODED {
        assert!(
            after.contains(c),
            "★ 既有类 `{c}` 必须仍在注册表里 —— 少了它 = 那个源静默失效（本条真正要守的东西）"
        );
    }
    // ② `FirstAid`：**已实现但未通电** ⇒ 必须不在（改前如此，增量批次也不许被顺手接上）
    assert!(
        !after.contains("FirstAid"),
        "★ csp_FirstAid 是「已实现但未通电」（四段真网络未全通）⇒ 不许被自动注册上"
    );
    /*
     * ③ 反面（防空真）：增量批次里"多"是**允许**的，但**不许**因此让这条退化成恒真。
     *    判据：注册表**至少**含既有 5 类 —— 用"少于 5 就红"来兜住"一个都没注册"的极端。
     *    ⚠️ 若将来既有类被有意删除，这里会红，那时**要连同本注释一起改**（别只改数字）。
     */
    assert!(
        after.len() >= BEFORE_HARDCODED.len(),
        "★ 注册表至少要有既有那 {} 个类（实际 {}）—— 这条兜住「注册机制整个失效」",
        BEFORE_HARDCODED.len(),
        after.len()
    );
}

#[test]
fn r3_no_hardcoded_insert_remains() {
    let src = std::fs::read_to_string("src/csp/mod.rs").expect("读 mod.rs");
    /*
     * ⚠️⚠️ **必须剥掉注释再判** —— 本仓已经踩过两次这个坑
     *    （`.probe/t66-scanner-blockcomment-scope.md`）：
     *    文件里那段**解释"改前是什么"**的注释逐字写着
     *    `// \`build_registry()\` 里**逐行 \`m.insert(类::CLASS, || …)\` 写死**：`
     *    ⇒ 裸 `contains("m.insert(")` 会把**注释**也算成违规 ⇒ 假红，
     *      而"修法"只能是去删那段讲历史决策的注释（把有价值的留档逼没了）。
     * ⇒ 剥注释（行注释 + 块注释），只看**代码**。
     */
    let code: String = {
        let mut out = String::new();
        let mut in_block = false;
        for line in src.lines() {
            let t = line.trim_start();
            if in_block {
                if let Some(p) = t.find("*/") {
                    in_block = false;
                    out.push_str(&t[p + 2..]);
                    out.push('\n');
                }
                continue;
            }
            if let Some(p) = t.find("/*") {
                // 同行闭合的块注释不算进入块（`/* … */`）
                let rest = &t[p + 2..];
                if rest.contains("*/") {
                    out.push_str(t[..p].trim_end());
                    out.push('\n');
                } else {
                    in_block = true;
                    out.push_str(&t[..p]);
                    out.push('\n');
                }
                continue;
            }
            if t.starts_with("//") {
                out.push('\n');
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        out
    };
    /*
     * ★★ 判据要**瞄准缺陷形状**，不是瞄"出现过 m.insert 这四个字母"。
     *
     * 我第一版写成 `!code.contains("m.insert(")` ⇒ **假红**：
     *   `build_registry_from` 里有一句 `m.insert(reg.class, reg.make)` ——
     *   那是**从注册项收集**（每来一条插一条），是**正确且必需**的，
     *   与"把类名写死在核心"完全不是一回事。
     * ⇒ 缺陷形状是：**`m.insert(<具体类名>::CLASS, …)`** —— 即"逐个类写死"。
     *   判据：核心的**代码**里不许出现 `m.insert(` **紧跟一个具体类名**（`::CLASS`）。
     *   ★ 这条能红：把 `bili::Bili::CLASS` 那一行加回来 ⇒ 立刻命中。
     */
    let hardcoded = Regex::new(r"m\.insert\(\s*[A-Za-z_][A-Za-z0-9_]*::[A-Za-z_][A-Za-z0-9_]*::CLASS")
        .expect("正则");
    assert!(
        !hardcoded.is_match(&code),
        "★ 核心**代码**里不许再出现「写死某个类」的注册（`m.insert(<某类>::CLASS, …)`）——\
         那正是本项要消灭的形态（69 个待补类 = 69 行写死，Owner 说的耦合太严重）。\
         ⚠️ 只判代码：注释里描述「改前是什么」是**留档**，不许被这条逼着删掉。"
    );
    /*
     * 反面：`build_registry_from` 里那一次**收集式** `m.insert(reg.class, …)`
     * 必须**仍在** —— 否则说明我把机制本身删了（那这条门禁就变成"什么都不许写"了）。
     */
    assert!(
        code.contains("m.insert(reg.class, reg.make)"),
        "★ 机制本体必须在：`m.insert(reg.class, reg.make)` 是从注册项**收集**的那一句"
    );
    // 自注册必须长在**类自己的文件**里（不是核心）
    for (f, cls) in [
        ("bili.rs", "Bili"),
        ("app99.rs", "App99"),
        ("ikanbot.rs", "Ikanbot"),
        ("pan_web_share.rs", "PanWebShare"),
        ("zhinan.rs", "Zhinan"),
    ] {
        let s = std::fs::read_to_string(format!("src/csp/{f}")).expect("读类文件");
        assert!(
            s.contains(&format!("register_site!({cls})")),
            "★ {f} 必须自注册 {cls}（新增类 = 新增文件，不改核心）"
        );
    }
}

#[test]
fn r3_duplicate_class_is_a_loud_error() {
    /*
     * ★★★ 验收②：同名 CLASS 冲突必须**显式报错**，不许静默覆盖。
     *
     * 为什么不能只靠"我注入了两个同名类、跑一遍看红不红"：
     * `inventory` 的收集是**链接期**的 —— 在同一个 test binary 里
     * 我没法临时"再注册一个"（那需要再写一个 `submit!`，而它一旦写进
     * 任何被编译的文件里，就**永久**污染了这个 binary）。
     * ⇒ 所以判据做成**纯函数级**：把"构建 + 冲突检测"抽成
     *    `build_registry_from_inventory()`，这里用**直接构造的输入**
     *    驱动它的冲突分支，断言它返回 `Err` 且**点名了那个类**。
     *    ⇒ 这不是"退化成测一个辅助函数"：生产 `registry()` 走的**就是**
     *      同一个函数（见 mod.rs 里 `Lazy::new(|| build_registry_from_inventory()…)`），
     *      所以这条覆盖的是**真实路径**。
     */
    let dup = vec![
        csp::CspRegistration { class: "DupX", make: mk_dummy },
        csp::CspRegistration { class: "DupX", make: mk_dummy },
    ];
    let err = csp::build_registry_from(dup).expect_err("两个同名类必须报错");
    assert!(err.contains("DupX"), "报错必须**点名**重复的类名：{err}");
    assert!(err.contains("重复注册"), "要说清是「重复注册」：{err}");

    // 反面：不重复时正常成表（否则上面那条可能只是"永远失败"= 恒真）
    let ok = vec![
        csp::CspRegistration { class: "Aoe", make: mk_dummy },
        csp::CspRegistration { class: "Boe", make: mk_dummy },
    ];
    let m = csp::build_registry_from(ok).expect("不重复必须成功");
    assert_eq!(m.len(), 2, "两张表都进去");
}

#[test]
fn r3_registration_validates_class_name() {
    // 空类名 ⇒ 报错（否则是一个"注册了但谁也匹配不到"的静默项）
    let empty = vec![csp::CspRegistration { class: "", make: mk_dummy }];
    let err = csp::build_registry_from(empty).expect_err("空类名必须报错");
    assert!(err.contains("空串"), "文案要点明空类名：{err}");

    // 含非法字符 ⇒ 报错（`class_of` 只认 [A-Za-z0-9_] ⇒ 它永远匹配不上配置）
    let bad = vec![csp::CspRegistration { class: "Bad Name", make: mk_dummy }];
    let err = csp::build_registry_from(bad).expect_err("非法字符必须报错");
    assert!(err.contains("非法字符"), "文案要点明字符约束：{err}");
}

#[test]
fn r3_unregistered_class_keeps_exact_wording() {
    // 验收④：未注册的类**逐字**仍是 `csp_X 尚未实现`
    assert_eq!(csp::unimplemented_reason("csp_DongLi"), "csp_DongLi 尚未实现");
    assert_eq!(csp::unimplemented_reason("csp_XBPQ"), "csp_XBPQ 尚未实现");
    assert!(!csp::is_implemented("csp_DongLi"), "未注册类不许被判为已实现");
}

#[test]
fn r3_class_files_have_no_host_details() {
    /*
     * ★ 验收③：类实现文件里 grep 不到宿主细节 ⇒ "解耦"是**机器可验**的。
     * ⚠️ 只扫**非测试**段：测试里会起本地假上游、碰文件系统，
     *    那是测试的正当需要，不该算进"类实现的耦合度"。
     */
    let banned = ["crate::state", "crate::hostpool", "crate::proxy", "flutter"];
    for f in ["bili.rs", "app99.rs", "ikanbot.rs", "pan_web_share.rs", "zhinan.rs"] {
        let full = std::fs::read_to_string(format!("src/csp/{f}")).expect("读类文件");
        let impl_part = full.split("#[cfg(test)]").next().unwrap_or(&full);
        for b in banned {
            assert!(
                !impl_part.contains(b),
                "★ {f} 的**实现段**不许出现宿主细节 `{b}`（解耦约束，验收③）"
            );
        }
    }
}

// ── 测试用的最小实现（只为驱动冲突/校验分支）──
//
// ⚠️ 它**不实现 CspSite** —— 那些方法体对"注册表构建"这件事毫无关系，
//    写了只会变成一堆 `unimplemented!()` 噪声。注册项只需要一个
//    `fn() -> Arc<dyn CspSite>`，所以这里给一个**永远 panic 的构造器**即可
//    （构建注册表**不会调用**构造器，只存函数指针）。
fn mk_dummy() -> std::sync::Arc<dyn CspSite> {
    panic!("测试用：注册表构建不应调用构造器")
}