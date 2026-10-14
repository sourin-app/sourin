//! 内置 Provider 集合
//!
//! ★ 架构口径（Owner 逐字）：客户端只提供**视频播放能力**；
//!   具体的视频网站由用户的**本地插件**提供，不进仓库。
//!   所以这里只有**通用**的 Provider —— 任何"某个具体网站"的实现
//!   都必须走插件（`plugins/*.js`）或声明式 JSON，不内置在 Rust 里。
//!   声明式 Provider（用户写 JSON 接入标准站）
pub mod declarative;
/// HTTP Provider（进程外插件契约）—— 见 `providers/http.rs`
pub mod http;

pub use declarative::DeclarativeProvider;
pub use http::HttpProvider;
