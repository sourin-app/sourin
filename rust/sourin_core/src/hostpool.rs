// ═══════════════════════════════════════════════════════════════════════
//  域名池（host pool）—— 插件提供候选域名，宿主决定怎么选/何时换
// ═══════════════════════════════════════════════════════════════════════
//
// # 职责划分（Owner 2026-10-17 口径，逐字）
//
// ```text
// 多 host 由插件提供，自动轮值由软件本身实现
// ```
// ⇒ 插件给**数据**（一个有序域名列表），宿主给**算法**。
// ⇒ 因此本文件**不认识任何具体域名** —— 它只处理
//   「一批字符串 + 当前索引 + 失败计数」。这是刻意的：
//   一旦这里出现站点知识，它就退化成「内置站点」而不是「通用能力」。
//
// # 为什么放在宿主而不是让每个插件自己重试
//
// ```text
// ① 插件自己写 = 每个插件重写一遍，且**重启就忘**
//    （用户第二天打开又撞上昨天那个坏域名）
// ② 失败的记忆必须跨重启 ⇒ 必须落盘 ⇒ 只有宿主有稳定的数据目录
// ③ 选路策略应当全局一致，否则每个插件的重试手感都不一样
// ```
//
// # 算法（这是「自动轮值」的核心，每条都对应一个具体失败模式）
//
// ```text
// 成功        ⇒ 该域名 failures 归零，并**锁定**为 current
//               （不随便换 —— 抖动会让缓存/会话/登录态反复失效）
// 失败        ⇒ failures += 1，若 current 就是它则切到下一个健康域名
// 失败 ≥ N 次 ⇒ 进入冷却，冷却期内不选它
// 冷却到期    ⇒ failures **减半**（不是清零！）后重新入候选
//               清零会让刚恢复的坏域名立刻被重选、马上再失败，来回撞墙
// 全在冷却    ⇒ 选 failures 最少的（**保证总有能用的**，宁可降级不空转）
// ```
//
// ⚠️ 两条容易被写错的判据：
// ```text
// · 「不许因为一次偶发失败就永久弃用」—— 所以是冷却 + 减半，不是拉黑
// · 「不许每次都重新随机选」—— 所以成功了要锁定，不是每轮重算
// ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// 失败多少次进入冷却
///
/// 3 是刻意取的：1~2 次可能只是网络抖动（用户切 WiFi、地铁过隧道），
/// 到 3 次才更像「这个域名真的挂了」。太小会频繁误判，太大会让用户
/// 连续吃好几次失败才看到切换。
pub const COOLDOWN_AFTER_FAILURES: u32 = 3;

/// 冷却时长（秒）
///
/// 10 分钟：短到用户重开应用时大概率已过期，长到不会在一次会话里反复撞。
pub const COOLDOWN_SECS: u64 = 600;

/// 一个域名的运行状态
///
/// 与 `HostPool` 分开，是为了让「插件声明的数据」和「宿主记住的状态」
/// 不混在一个结构里 —— 前者来自插件、后者来自落盘，生命周期不同。
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct HostState {
    /// 连续失败次数（成功即清零）
    pub failures: u32,
    /// 冷却截止时间（unix 秒）；0 = 不在冷却
    #[serde(skip_serializing_if = "is_zero")]
    pub cool_until: u64,
}

fn is_zero(v: &u64) -> bool {
    *v == 0
}

impl HostState {
    /// 是否在冷却中
    pub fn cooling(&self, now: u64) -> bool {
        self.cool_until > now
    }
}

/// 域名池 —— 插件声明的候选 + 宿主记住的状态
///
/// # 为什么 `current` 存**域名**而不是索引
///
/// ```text
/// 索引会在插件改了 hosts 顺序后**指向错的那个** ——
/// 而且错得很隐蔽（不报错，只是换成了一个用户没预期的域名）。
/// 存域名则最坏情况是「那个域名没了」⇒ 自然回退到重新选择，行为可解释。
/// ```
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct HostPool {
    /// 候选域名（去重后保留插件给的顺序）
    pub hosts: Vec<String>,
    /// 当前锁定的域名；None = 还没选过
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current: Option<String>,
    /// 每个域名的状态（key = 域名）
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub states: BTreeMap<String, HostState>,
}

impl HostPool {
    /// 从插件声明的域名列表建池（去重、保序、丢掉空串）
    pub fn from_hosts(hosts: Vec<String>) -> Self {
        let mut seen = std::collections::HashSet::new();
        let cleaned: Vec<String> = hosts
            .into_iter()
            .map(|h| h.trim().trim_end_matches('/').to_string())
            .filter(|h| !h.is_empty())
            .filter(|h| seen.insert(h.clone()))
            .collect();
        Self {
            hosts: cleaned,
            current: None,
            states: BTreeMap::new(),
        }
    }

    /// 是否可用（没有候选就用不了）
    pub fn is_empty(&self) -> bool {
        self.hosts.is_empty()
    }

    /// 插件换了域名列表时同步：保留仍然存在的状态，丢掉消失的
    ///
    /// ⚠️ 刻意**不**清空全部状态 —— 插件可能只是加了几个镜像域名，
    ///    那不该让「哪个域名坏了」的记忆一起丢失。
    pub fn sync_hosts(&mut self, hosts: Vec<String>) {
        let fresh = Self::from_hosts(hosts).hosts;
        self.states.retain(|k, _| fresh.contains(k));
        if let Some(cur) = &self.current {
            if !fresh.contains(cur) {
                self.current = None;
            }
        }
        self.hosts = fresh;
    }

    /// 选一个域名来用（`now` = unix 秒，注入以便测试）
    ///
    /// 顺序：锁定的 current → 第一个健康域名 → failures 最少的（全在冷却时）
    pub fn pick(&mut self, now: u64) -> Option<String> {
        if self.hosts.is_empty() {
            return None;
        }

        // ① 已锁定且仍健康 ⇒ 继续用它（不抖动）
        if let Some(cur) = &self.current {
            if self.hosts.contains(cur) {
                let st = self.states.get(cur).cloned().unwrap_or_default();
                if !st.cooling(now) {
                    return Some(cur.clone());
                }
            }
        }

        // ② 健康域名里 failures 最少的；同失败数时按插件给的顺序
        //
        // 这里不能只取「第一个 failures < 3 的」—— 那样冷却恢复的域名
        // （failures 减半后 < 3）会排到零失败的域名前面，
        // 刚恢复就又被选中、马上再失败，来回撞墙。
        // 实测：tests/t37_hostpool.rs 的 revived_host_ranks_behind_healthy_one 就是为此加的。
        let mut best: Option<(&String, u32)> = None;
        for h in &self.hosts {
            let st = self.states.get(h).cloned().unwrap_or_default();
            if st.cooling(now) {
                continue;
            }
            match best {
                None => best = Some((h, st.failures)),
                Some((_, bf)) if st.failures < bf => best = Some((h, st.failures)),
                _ => {}
            }
        }
        if let Some((h, _)) = best {
            self.current = Some(h.clone());
            return Some(h.clone());
        }

        // ③ 全在冷却 / 全失败够多 ⇒ 选 failures 最少的
        //
        // 保证「总有能用的」：宁可试一个明知不稳的，也不返回 None
        // 让调用方以为「这个源完全没救」。
        let best = self
            .hosts
            .iter()
            .min_by_key(|h| {
                let st = self.states.get(*h).cloned().unwrap_or_default();
                // 冷却中的排后面；同为冷却则比失败次数
                (st.cooling(now) as u8, st.failures)
            })
            .cloned();
        self.current = best.clone();
        best
    }

    /// 记一次成功：清零失败数并锁定
    pub fn record_success(&mut self, host: &str) {
        let st = self.states.entry(host.to_string()).or_default();
        st.failures = 0;
        st.cool_until = 0;
        if self.hosts.iter().any(|h| h == host) {
            self.current = Some(host.to_string());
        }
    }

    /// 记一次失败：+1，够次数就进冷却
    ///
    /// 返回该域名**是否刚进入冷却**（调用方可据此记日志/换源）。
    pub fn record_failure(&mut self, host: &str, now: u64) -> bool {
        let st = self.states.entry(host.to_string()).or_default();
        st.failures = st.failures.saturating_add(1);
        if st.failures >= COOLDOWN_AFTER_FAILURES && !st.cooling(now) {
            st.cool_until = now + COOLDOWN_SECS;
            return true;
        }
        false
    }

    /// 冷却到期的域名：failures 减半后重新入候选
    ///
    /// ⚠️ **减半而不是清零** —— 清零会让刚恢复的坏域名立刻被重新选；
    ///    减半保留了「它历史上有问题」的记忆，让它排在健康域名之后。
    pub fn revive_cooled(&mut self, now: u64) {
        for st in self.states.values_mut() {
            if st.cool_until != 0 && st.cool_until <= now {
                st.cool_until = 0;
                st.failures /= 2;
            }
        }
    }
}

// ─────────────────────────── 落盘 ───────────────────────────

/// 池状态文件路径
///
/// ⚠️ 与 `persist.rs` 的 `third-party-providers.json` **同一目录**，
///    不新开目录（Lead 的硬要求）。
pub fn pool_file(dir: &Path) -> PathBuf {
    dir.join("host-pools.json")
}

/// 全部插件的池状态（key = 插件 id）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct HostPools {
    pub pools: BTreeMap<String, HostPool>,
}

/// 读池状态
///
/// # 容错（与 persist.rs 同一纪律）
///
/// ```text
/// 文件不存在 → 空（首次启动的正常情况）
/// 文件损坏   → 记 warn + 空（**不能崩** —— 一份坏 JSON 不该让应用起不来）
/// ```
pub fn load(dir: &Path) -> HostPools {
    let p = pool_file(dir);
    match std::fs::read_to_string(&p) {
        Ok(s) => serde_json::from_str(&s).unwrap_or_else(|e| {
            log::warn!("域名池状态解析失败（将重建）: {e}");
            HostPools::default()
        }),
        Err(_) => HostPools::default(),
    }
}

/// 写池状态（原子替换：先写临时文件再 rename）
///
/// ⚠️ 直接覆写会在写入中途断电时**丢掉全部历史**（用户又要重新喂一遍坏域名）。
pub fn save(dir: &Path, all: &HostPools) -> Result<(), String> {
    let p = pool_file(dir);
    let tmp = p.with_extension("json.tmp");
    let s = serde_json::to_string_pretty(all).map_err(|e| format!("序列化失败: {e}"))?;
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("建目录失败: {e}"))?;
    }
    std::fs::write(&tmp, s).map_err(|e| format!("写临时文件失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换失败: {e}"))?;
    Ok(())
}
