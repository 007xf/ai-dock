import Foundation

struct LocalModel: Identifiable, Hashable {
    let id: String
    var sizeBytes: Int64?
    var loaded: Bool
    var detail: String?
}

struct LocalModelsInfo: Equatable {
    var running = false
    var models: [LocalModel] = []
    var loadedCount: Int { models.filter(\.loaded).count }
}

/// 本地模型：Ollama / LM Studio。服务在运行时读本机接口（已安装 + 已加载），否则只列出已下载的模型目录。
enum LocalModelsProvider {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        return URLSession(configuration: c)
    }()

    static func fetch(_ id: String) async -> LocalModelsInfo {
        switch id {
        case "ollama": return await ollama()
        case "lmstudio": return await lmstudio()
        default: return LocalModelsInfo()
        }
    }

    private static func get(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url), let (data, resp) = try? await session.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func ollama() async -> LocalModelsInfo {
        var info = LocalModelsInfo()
        if let tags = await get("http://127.0.0.1:11434/api/tags") {
            info.running = true
            let loaded = Set(((await get("http://127.0.0.1:11434/api/ps"))?["models"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String })
            for m in tags["models"] as? [[String: Any]] ?? [] {
                guard let name = m["name"] as? String else { continue }
                let d = m["details"] as? [String: Any]
                let detail = [d?["parameter_size"] as? String, d?["quantization_level"] as? String].compactMap { $0 }.joined(separator: " · ")
                info.models.append(LocalModel(id: name, sizeBytes: (m["size"] as? NSNumber)?.int64Value,
                                              loaded: loaded.contains(name), detail: detail.isEmpty ? nil : detail))
            }
        } else {
            info.models = downloadedOllamaModels()
        }
        info.models.sort { ($0.loaded ? 0 : 1, $0.id) < ($1.loaded ? 0 : 1, $1.id) }
        return info
    }

    /// 服务没开：列出已下载的模型（manifests/<registry>/<namespace>/<model>/<tag>）
    private static func downloadedOllamaModels() -> [LocalModel] {
        var out: [LocalModel] = []
        let root = FileManager.default.home.appendingPathComponent(".ollama/models/manifests")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let model = url.deletingLastPathComponent().lastPathComponent
            out.append(LocalModel(id: "\(model):\(url.lastPathComponent)", loaded: false))
        }
        return out
    }

    private static func lmstudio() async -> LocalModelsInfo {
        var info = LocalModelsInfo()
        if let r = await get("http://127.0.0.1:1234/api/v0/models") {
            info.running = true
            for m in r["data"] as? [[String: Any]] ?? [] where (m["type"] as? String ?? "llm") != "embeddings" {
                guard let id = m["id"] as? String else { continue }
                let detail = [m["arch"] as? String, m["quantization"] as? String].compactMap { $0 }.joined(separator: " · ")
                info.models.append(LocalModel(id: id, loaded: (m["state"] as? String) == "loaded",
                                              detail: detail.isEmpty ? nil : detail))
            }
        } else {
            // 服务没开：列出已下载的模型（~/.lmstudio/models/<发布者>/<模型>）
            let root = FileManager.default.home.appendingPathComponent(".lmstudio/models")
            for pub in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where !pub.hasPrefix(".") {
                for model in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(pub).path)) ?? [] where !model.hasPrefix(".") {
                    info.models.append(LocalModel(id: model, loaded: false, detail: pub))
                }
            }
        }
        info.models.sort { ($0.loaded ? 0 : 1, $0.id) < ($1.loaded ? 0 : 1, $1.id) }
        return info
    }
}
