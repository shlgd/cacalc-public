import Foundation
import Darwin
#if canImport(CoreML) && canImport(Tokenizers)
import CoreML
import Tokenizers
#endif

/// One actor owns the encoder and its vectors. Lexical lookup never depends on availability.
actor SemanticProductSearch {
    static let shared: SemanticProductSearch = {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["CACALC_TEST_CACHE_DIRECTORY"] {
            return SemanticProductSearch(cacheURL: URL(fileURLWithPath: path).appendingPathComponent("vectors.json"))
        }
        #endif
        return SemanticProductSearch()
    }()
    struct CachedVector: Codable { var text: String; var vector: [Float] }
    struct Result: Sendable {
        var scores: [String: Double] = [:]
        var status = "unavailable"
        var seconds: Double = 0
        var truncated = false
    }
    private var startupTask: Task<Void, Never>?
    /// App startup and the first search share this actor and the same model/cache.
    func warmUp(products: [Product]) async {
        if let startupTask { await startupTask.value; return }
        let task = Task {
            _ = await scores("продукт", products: products, trigger: "app-startup")
        }
        startupTask = task
        await task.value
        startupTask = nil
    }
    private var loadMetrics: [String: String] = [:]
    private var vectors: [String: CachedVector] = [:]
    private var loadedCache = false
    private var retryAfter: Date?
    private var queryCache: [String: [Float]] = [:]
    private let cacheURL: URL
    private let encoderOverride: (@Sendable (String) throws -> [Float])?
    private let preparationOverride: (@Sendable () async throws -> Void)?
    private let retryDelay: TimeInterval
    init(cacheURL: URL = URL.applicationSupportDirectory.appendingPathComponent("FoodSearch/e5-v1-vectors.json"),
         encoder: (@Sendable (String) throws -> [Float])? = nil,
         prepare: (@Sendable () async throws -> Void)? = nil, retryDelay: TimeInterval = 1) {
        self.cacheURL = cacheURL; encoderOverride = encoder; preparationOverride = prepare; self.retryDelay = retryDelay
    }
    private var preparation: Task<Void, Error>?
    #if canImport(CoreML) && canImport(Tokenizers)
    private var model: MLModel?
    private var tokenizer: (any Tokenizer)?
    #endif
    private func prepare() async throws {
        if let preparation { try await preparation.value; return }
        let task = Task {
            if let preparationOverride { try await preparationOverride() }
            else if encoderOverride == nil {
                #if canImport(CoreML) && canImport(Tokenizers)
                try await loadModel()
                #else
                throw FoodError.database("Embedding not linked")
                #endif
            }
        }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }
    #if canImport(CoreML) && canImport(Tokenizers)
    private func loadModel() async throws {
        guard model == nil else { return }
        guard let folder = Bundle.main.url(forResource: "FoodSearch", withExtension: nil),
              let compiled = Bundle.main.url(forResource: "FoodEmbedding", withExtension: "mlmodelc") else {
            throw FoodError.database("Embedding assets unavailable")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let modelStart = Date()
        let loaded = try MLModel(contentsOf: compiled, configuration: config)
        loadMetrics["modelLoadSeconds"] = String(Date().timeIntervalSince(modelStart))
        let tokenizerStart = Date()
        let tokens = try await AutoTokenizer.from(modelFolder: folder.appendingPathComponent("tokenizer"))
        loadMetrics["tokenizerLoadSeconds"] = String(Date().timeIntervalSince(tokenizerStart))
        model = loaded; tokenizer = tokens
    }
    #endif
    private func encode(_ text: String) throws -> (vector: [Float], truncated: Bool) {
        if let encoderOverride { return (try encoderOverride(text), false) }
        #if canImport(CoreML) && canImport(Tokenizers)
        guard let model, let tokenizer else { throw FoodError.database("Embedding not prepared") }
        let encoded = tokenizer.encode(text: text)
        var ids = Array(encoded.prefix(64))
        if encoded.count > 64, let end = encoded.last { ids[63] = end }
        let input = try MLMultiArray(shape: [1,64], dataType: .int32)
        let mask = try MLMultiArray(shape: [1,64], dataType: .int32)
        for i in 0..<64 { input[i] = NSNumber(value: i < ids.count ? ids[i] : 1); mask[i] = NSNumber(value: i < ids.count ? 1 : 0) }
        let values = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask])
        let result = try model.prediction(from: values)
        guard let array = result.featureValue(for: "embedding")?.multiArrayValue, array.count == 384 else { throw FoodError.database("Invalid embedding shape") }
        var vector = (0..<384).map { array[$0].floatValue }
        let norm = sqrt(vector.reduce(Float(0)) { $0+$1*$1 })
        guard norm.isFinite && norm > 0 else { throw FoodError.database("Invalid embedding norm") }
        for i in vector.indices { vector[i] /= norm }
        return (vector, encoded.count > 64)
        #else
        throw FoodError.database("Embedding not linked")
        #endif
    }
    func scores(_ phrase: String, products: [Product], trigger: String = "search") async -> Result {
        let started = Date()
        var metrics: [String: String] = ["operationID": UUID().uuidString, "trigger": trigger, "query": phrase, "productCount": String(products.count)]
        #if canImport(CoreML) && canImport(Tokenizers)
        do { try await MatchingLog.shared.write("semanticStarted", fields: metrics) }
        catch { NSLog("Semantic diagnostics write failed: %@", error.localizedDescription) }
        #endif
        metrics.merge(ProcessMemory.fields().map { ("before_" + $0.key, $0.value) }.reduce(into: [String:String]()) { $0[$1.0] = $1.1 }) { _, new in new }
        let result = await measuredScores(phrase, products: products, metrics: &metrics)
        metrics.merge(ProcessMemory.fields()) { _, new in new }
        metrics["status"] = result.status
        metrics["totalSeconds"] = String(Date().timeIntervalSince(started))
        #if canImport(CoreML) && canImport(Tokenizers)
        do { try await MatchingLog.shared.write("semanticTiming", fields: metrics) }
        catch { NSLog("Semantic diagnostics write failed: %@", error.localizedDescription) }
        #endif
        return result
    }
    func reconcileCatalog(_ products: [Product]) {
        let active = Set(products.map(\.id))
        for id in Array(vectors.keys) where !active.contains(id) { vectors[id] = nil }
    }
    private func measuredScores(_ phrase: String, products: [Product], metrics: inout [String: String]) async -> Result {
        let start = Date()
        if let retryAfter, Date() < retryAfter { return Result(status:"retry-backoff",seconds:Date().timeIntervalSince(start)) }
        do {
            let preparationStart = Date()
            #if canImport(CoreML) && canImport(Tokenizers)
            metrics["modelCached"] = String(model != nil)
            #endif
            try await prepare()
            metrics["preparationSeconds"] = String(Date().timeIntervalSince(preparationStart))
            if metrics["modelCached"] == "false" { metrics.merge(loadMetrics) { _, new in new } }
            let cacheStart = Date()
            metrics["diskCacheAlreadyLoaded"] = String(loadedCache)
            if !loadedCache {
                if let folder = Bundle.main.url(forResource:"FoodSearch",withExtension:nil),
                   let data = try? Data(contentsOf: folder.appendingPathComponent("catalog-vectors.json")),
                   let cache = try? JSONDecoder().decode([String:CachedVector].self,from:data) { vectors = cache }
                if let data = try? Data(contentsOf:cacheURL),
                   let cache = try? JSONDecoder().decode([String:CachedVector].self,from:data) { vectors.merge(cache) { _,new in new } }
                loadedCache = true
            }
            metrics["cacheReadSeconds"] = String(Date().timeIntervalSince(cacheStart))
            let queryStart = Date()
            metrics["queryCached"] = String(queryCache[phrase] != nil)
            let query: [Float]
            var truncated = false
            if let cached = queryCache[phrase] { query = cached }
            else {
                let value = try encode("query: " + phrase)
                query = value.vector; truncated = value.truncated
                if queryCache.count >= 64 { queryCache.removeAll(keepingCapacity:true) }
                if !truncated { queryCache[phrase] = query }
            }
            metrics["queryEncodeSeconds"] = String(Date().timeIntervalSince(queryStart))
            var encodedProducts = 0
            var productEncodingSeconds = 0.0
            let catalogStart = Date()
            var changed = false
            var scores: [String:Double] = [:]
            for product in products {
                try Task.checkCancellation()
                let text = [product.name,product.brand].filter { !$0.isEmpty }.joined(separator:" ")
                if vectors[product.id]?.text != text || vectors[product.id]?.vector.count != query.count || vectors[product.id]?.vector.allSatisfy(\.isFinite) != true {
                    let encodeStart = Date()
                    let value = try encode("passage: " + text)
                    productEncodingSeconds += Date().timeIntervalSince(encodeStart)
                    encodedProducts += 1
                    vectors[product.id] = CachedVector(text:text,vector:value.vector)
                    changed = true
                }
                guard let vector = vectors[product.id]?.vector, vector.count == query.count,
                      vector.allSatisfy(\.isFinite) else { continue }
                scores[product.id] = zip(vector,query).reduce(0.0) { $0+Double($1.0*$1.1) }
            }
            metrics["encodedProducts"] = String(encodedProducts)
            metrics["productEncodeSeconds"] = String(productEncodingSeconds)
            metrics["catalogCompareSeconds"] = String(Date().timeIntervalSince(catalogStart) - productEncodingSeconds)
            let saveStart = Date()
            if changed {
                do {
                    try FileManager.default.createDirectory(at:cacheURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try JSONEncoder().encode(vectors).write(to:cacheURL,options:.atomic)
                } catch { metrics["cacheWriteError"] = error.localizedDescription }
            }
            metrics["cacheWriteSeconds"] = String(Date().timeIntervalSince(saveStart))
            return Result(scores:scores,status:"e5-v1",seconds:Date().timeIntervalSince(start),truncated:truncated)
        } catch is CancellationError { return Result(status:"cancelled",seconds:Date().timeIntervalSince(start)) }
        catch {
            // Explicitly reported to diagnostics; never prevents lexical matching.
            retryAfter = Date().addingTimeInterval(retryDelay)
            return Result(status:"error:" + error.localizedDescription,seconds:Date().timeIntervalSince(start))
        }
    }
}
