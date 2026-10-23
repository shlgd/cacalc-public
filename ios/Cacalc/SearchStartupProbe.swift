#if DEBUG
import Foundation

/// Explicit short, synthetic device check. Never reads or edits the user's diary.
enum SearchStartupProbe {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--search-probe") }
    static func checkpoint(_ stage: String) {
        let url = URL.applicationSupportDirectory.appendingPathComponent("search-probe.json")
        try? Data("{\"stage\":\"\(stage)\"}".utf8).write(to:url,options:.atomic)
    }
    static func run() async {
        let fixtures = [
            Product(id:"probe-boiled",name:"Картофель вареный",brand:"",basis:.g,source:"synthetic-probe"),
            Product(id:"probe-raw",name:"Картофель сырой",brand:"",basis:.g,source:"synthetic-probe"),
            Product(id:"probe-agro",name:"Гречка",brand:"Агроальянс",basis:.g,source:"synthetic-probe")
        ]
        checkpoint("started")
        let catalog = Catalog(url: Bundle.main.url(forResource: "catalog", withExtension: "sqlite"))
        let products = ((try? await catalog.browse()) ?? []) + fixtures
        checkpoint("catalog-loaded:\(products.count)")
        var output: [[String:Any]] = []
        for phrase in ["картошка отварная", "гречка агро альянс", "гречка аграальянс"] {
            let result = await SemanticProductSearch.shared.scores(phrase,products:products)
            let start = Date()
            let candidates = SearchIndex(products:products).rank(phrase,history:[],semantic:result.scores)
            output.append(["phrase":phrase,"catalogCount":products.count,"status":result.status,"semanticSeconds":result.seconds,
                "rankingSeconds":Date().timeIntervalSince(start),"scores":result.scores,
                "candidates":candidates.prefix(10).map { ["id":$0.id,"score":$0.score,"automatic":$0.automaticEligible] as [String:Any] }])
        }
        do {
            let url = URL.applicationSupportDirectory.appendingPathComponent("search-probe.json")
            try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        } catch { print("Search probe: \(error)") }
    }
}
#endif
