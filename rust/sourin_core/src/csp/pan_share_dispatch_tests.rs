use super::*;
use crate::csp::CspSite;

async fn assert_intermediate(site: &dyn CspSite, url: &str) {
    let plays = site.play("selected-line", &format!("pan|{url}"), "").await.unwrap();
    assert_eq!(plays.len(), 1);
    assert_eq!(plays[0].url, url);
    assert!(plays[0].label.as_deref().unwrap().contains("宿主检查解析"));
}

#[tokio::test]
async fn real_hj_baidu_share_reaches_intermediate_candidate() {
    assert_intermediate(&crate::csp::hjzhen_cai::HJZhenCai::new(), "https://pan.baidu.com/s/1fixture?pwd=test").await;
}

#[tokio::test]
async fn real_hj_xunlei_share_reaches_intermediate_candidate() {
    assert_intermediate(&crate::csp::hjzhen_cai::HJZhenCai::new(), "https://pan.xunlei.com/s/fixture?pwd=test").await;
}

#[tokio::test]
async fn real_wogg_baidu_share_reaches_intermediate_candidate() {
    assert_intermediate(&crate::csp::wogg::Wogg::new(), "https://pan.baidu.com/s/1fixture?pwd=test").await;
}

#[tokio::test]
async fn real_wogg_xunlei_share_reaches_intermediate_candidate() {
    assert_intermediate(&crate::csp::wogg::Wogg::new(), "https://pan.xunlei.com/s/fixture?pwd=test").await;
}

#[test]
fn intermediate_supported_shares_do_not_broaden_the_family_parser() {
    for url in ["https://pan.baidu.com/s/1fixture", "https://pan.xunlei.com/s/fixture"] {
        assert!(parse_share_page(url).is_none());
        assert!(share_page_play(url, "fixture-ua").is_some());
    }
}

#[test]
fn intermediate_candidates_reject_invalid_or_unhandled_urls() {
    for url in [
        "https://pan.baidu.com.evil.invalid/s/1fixture",
        "https://pan.xunlei.com.evil.invalid/s/fixture",
        "https://user:password@pan.baidu.com/s/1fixture",
        "ftp://pan.baidu.com/s/1fixture",
        "https://pan.baidu.com/s/1fixture\n",
        "https://pan.baidu.com/s/1fixture%0A",
        "https://pan.baidu.com/s/",
        "https://pan.baidu.com/disk/main",
        "https://115.com/s/fixture",
        "https://www.alipan.com/s/fixture",
        "https://cdn.example.invalid/video.m3u8",
    ] {
        assert!(share_page_play(url, "fixture-ua").is_none(), "Rejected fixture URL unexpectedly accepted");
    }
}
