use crate::proxy::ProxyStore;
use std::sync::{Arc, Mutex, RwLock};

type Policy = (Arc<ProxyStore>, String);

struct CachedClient {
    key: (usize, u64, String),
    client: reqwest::Client,
}

/// An engine keeps its builder recipe and state while routing follows the
/// current application policy. Never substitute a standalone client on error.
pub(crate) struct CspHttpContext {
    builder: Box<dyn Fn() -> reqwest::ClientBuilder + Send + Sync>,
    policy: RwLock<Option<Policy>>,
    cached: Mutex<Option<CachedClient>>,
}

impl CspHttpContext {
    pub(crate) fn new(builder: impl Fn() -> reqwest::ClientBuilder + Send + Sync + 'static) -> Self {
        Self {
            builder: Box::new(builder),
            policy: RwLock::new(None),
            cached: Mutex::new(None),
        }
    }

    pub(crate) fn set_proxy(&self, proxy: Arc<ProxyStore>, provider: &str) {
        *self.policy.write().unwrap() = Some((proxy, provider.to_string()));
        *self.cached.lock().unwrap() = None;
    }

    pub(crate) fn client(&self) -> Result<reqwest::Client, String> {
        let policy = self.policy.read().map_err(|_| "HTTP 请求策略忙")?.clone();
        let key = policy.as_ref().map(|(store, provider)|
            (Arc::as_ptr(store) as usize, store.policy_revision(), provider.clone())
        ).unwrap_or_default();
        let mut cached = self.cached.lock().map_err(|_| "HTTP 客户端忙")?;
        if let Some(cached) = cached.as_ref().filter(|cached| cached.key == key) {
            return Ok(cached.client.clone());
        }
        let builder = (self.builder)();
        let builder = match policy {
            Some((store, provider)) => store.client_builder_for(&provider, builder).map_err(|e| e.message)?,
            None => builder.no_proxy(),
        };
        let client = builder.build().map_err(|_| "无法建立源请求客户端")?;
        *cached = Some(CachedClient { key, client: client.clone() });
        Ok(client)
    }
}

#[cfg(test)]
#[path = "http_test_support.rs"]
pub(crate) mod test_support;

#[cfg(test)]
#[path = "http_context_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
#[path = "http_context_factory_tests.rs"]
mod factory_tests;
