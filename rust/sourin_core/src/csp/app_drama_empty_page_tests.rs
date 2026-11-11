//! Public-provider empty-page regressions with literal protobuf envelopes.
//! Only loopback proxy traffic; no account access or media requests.
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use crate::provider::{ListRequest, MediaProvider};
use std::sync::{Arc, RwLock};

#[path = "app_drama_public_fixture.rs"]
mod public_fixture;
use public_fixture::{ext_for, fixtures, respond, ResponseMode, LIST, SEARCH, ZONE};

// ApiResponse {code:200, data:Page {total:0/21}} with no repeated items.
// These bytes are handwritten from the field schema, never candidate-encoded.
const EMPTY_ZERO: &str = "08c8011a03800100";
const EMPTY_END: &str = "08c8011a03800115";

struct PageFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
    envelope: Arc<RwLock<String>>,
}

impl PageFixture {
    async fn new(envelope: &str) -> Self {
        let origin = serve(|_| panic!("public provider may never retry outside its proxy")).await;
        let domain = origin.url.clone();
        let envelope = Arc::new(RwLock::new(envelope.to_owned()));
        let selected = envelope.clone();
        let golden = fixtures();
        let proxy = serve(move |request| {
            let mut data = golden.clone();
            data["pageHex"] = selected.read().unwrap().clone().into();
            // The existing independent inspector decrypts the actual default
            // constructor's publicParams/body and checks exact wire parameters.
            respond(&request, &data, &domain, ResponseMode::Normal)
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let ext = ext_for(&origin.url);
        Self { origin, proxy, store, ext, envelope }
    }

    fn provider(&self) -> crate::csp::provider::CspProvider {
        // Exercise the registered public constructor, not for_test or an
        // injected engine. This is the production import/restore call path.
        crate::csp::provider::CspProvider::new(
            "synthetic-page-fixture", "Synthetic page fixture", "csp_AppDrama",
            &self.ext, vec![], false, false,
        ).unwrap().with_proxy(self.store.clone())
    }

    fn envelope(&self, value: &str) {
        *self.envelope.write().unwrap() = value.to_owned();
    }

    fn assert_requests(&self, search: usize, list: usize) {
        assert!(self.origin.hits.lock().unwrap().is_empty(), "zero origin fallback requests");
        let hits = self.proxy.hits.lock().unwrap();
        assert_eq!(hits.iter().filter(|hit| hit.uri.path() == "/dispatch").count(), 1);
        assert_eq!(hits.iter().filter(|hit| hit.uri.path() == ZONE).count(), 1);
        assert_eq!(hits.iter().filter(|hit| hit.uri.path() == SEARCH).count(), search);
        assert_eq!(hits.iter().filter(|hit| hit.uri.path() == LIST).count(), list);
        assert_eq!(hits.len(), 2 + search + list, "no hidden retry or extra media request");
    }
}

#[tokio::test]
async fn app_drama_empty_page_public_provider_search_and_category_are_normal_zero_results() {
    let fixture = PageFixture::new(EMPTY_ZERO).await;
    let provider = fixture.provider();
    let search = provider.search("synthetic-query", 1).await
        .expect("a valid zero-hit search is a normal page, not a source parse failure");
    assert!(search.items.is_empty());
    assert_eq!(search.page, 1);
    let category = provider.list(ListRequest {
        category_id: "cat-one".into(), page: 1, ..Default::default()
    }).await.expect("a valid empty category is a normal page");
    assert!(category.items.is_empty());
    assert_eq!(category.page, 1);
    fixture.assert_requests(1, 1);

    // An empty page after the last available page keeps reported pagination.
    fixture.envelope(EMPTY_END);
    let end = provider.list(ListRequest {
        category_id: "cat-one".into(), page: 2, ..Default::default()
    }).await.expect("an empty final page is not malformed protocol data");
    assert!(end.items.is_empty());
    assert_eq!((end.page, end.total, end.page_count), (2, Some(21), Some(1)));

    // The same cached public session remains usable for real items afterward.
    fixture.envelope(fixtures()["pageHex"].as_str().unwrap());
    let found = provider.search("synthetic-query", 1).await.unwrap();
    assert_eq!(found.items[0].id.native, "1001");
    fixture.assert_requests(2, 2);
}

#[tokio::test]
async fn app_drama_empty_page_malformed_or_missing_data_stays_an_explicit_error() {
    for envelope in [
        "08c801",                         // success code but no data field
        "08c8011a00",                     // explicitly empty data, no Page shape
        "08c8011a03a00101",               // only unknown Page field 20
        "08c8011a06850100000000",         // total field 16 uses fixed32
        "08c8011a0c8001ffffffffffffffffff01", // total field 16 is signed -1
        "08c8011a070a0518012a0278",       // malformed nested row: truncated text
    ] {
        let fixture = PageFixture::new(envelope).await;
        let provider = fixture.provider();
        let error = provider.search("synthetic-query", 1).await
            .expect_err("an empty-result fix must still reject absent/unknown/malformed data");
        assert!(!error.message.contains(&fixture.origin.url));
        assert!(!error.message.contains("publicParams"));
        fixture.assert_requests(1, 0);
    }
}
