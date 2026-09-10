import WebKit

/// The compiled content rule list that decides which hosts the page may
/// reach. Built by the `Net` extension; block-all when there is none.
@MainActor
final class NetworkPolicy {
    let ruleList: WKContentRuleList?
    init(ruleList: WKContentRuleList?) { self.ruleList = ruleList }
}
