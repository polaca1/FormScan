import UIKit

struct InferenceJob {
    let model: AIModel
    let url: URL
}
struct InferenceResult {
    enum Fields { case success([DetectedField]), failure(String) }
    let model: AIModel
    let fields: Fields
}

enum FieldEnsemble {
    /// Results are emitted in completion order, with bounded native inference memory.
    @MainActor
    static func run(image: UIImage, jobs: [InferenceJob], parallelism: Int,
                    receive: (InferenceResult, Int) -> Void) async {
        await withTaskGroup(of: InferenceResult.self) { group in
            var next = 0, completed = 0
            func enqueue(_ job: InferenceJob) {
                group.addTask {
                    if Task.isCancelled { return InferenceResult(model: job.model, fields: .failure("Cancelado")) }
                    return await Task.detached(priority: .userInitiated) {
                        do {
                            let fields = try autoreleasepool { try LocalFieldAI.detect(image, model: job.model, modelURL: job.url) }
                            return InferenceResult(model: job.model, fields: .success(fields))
                        } catch { return InferenceResult(model: job.model, fields: .failure(error.localizedDescription)) }
                    }.value
                }
            }
            for _ in 0..<min(max(1, parallelism), jobs.count) { enqueue(jobs[next]); next += 1 }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); continue }
                completed += 1; receive(result, completed)
                if next < jobs.count { enqueue(jobs[next]); next += 1 }
            }
        }
    }

    /// Agreement is evaluated by family: the two Nano variants share one vote.
    /// Cross-family agreement refines geometry; confidence is not calibrated accuracy.
    static func fuse(_ results: [AIModel: [DetectedField]]) -> [DetectedField] {
        struct Vote { let model: AIModel; let field: DetectedField }
        var clusters: [[Vote]] = []
        for model in AIModel.allCases {
            for field in results[model] ?? [] {
                if let index = clusters.firstIndex(where: { cluster in
                    cluster.contains { vote in
                        vote.field.rect.intersection(field.rect).area > min(vote.field.rect.area, field.rect.area) * 0.5
                    }
                }) { clusters[index].append(Vote(model: model, field: field)) }
                else { clusters.append([Vote(model: model, field: field)]) }
            }
        }
        return clusters.compactMap { cluster in
            // FP32 is the preferred Nano representative when both have completed.
            let nano = cluster.first { $0.model == .nano } ?? cluster.first { $0.model == .compact }
            let detailed = cluster.first { $0.model == .detailed }
            if let nano, let detailed, nano.field.category == detailed.field.category {
                let a = nano.field.rect, b = detailed.field.rect
                return DetectedField(rect: CGRect(x: (a.minX+b.minX)/2, y: (a.minY+b.minY)/2,
                                                  width: (a.width+b.width)/2, height: (a.height+b.height)/2),
                                     category: nano.field.category, confidence: max(nano.field.confidence, detailed.field.confidence))
            }
            // Preserve a useful single-family result; another model not finding
            // a field is not proof that it does not exist. No synthetic confidence boost.
            return nano?.field ?? detailed?.field
        }.sorted { $0.rect.minY < $1.rect.minY }
    }
}
