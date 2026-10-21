import Foundation

enum FieldReconciliation {
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.intersection(b).area > min(a.area, b.area) * 0.5
    }
    static func conflictsWithExplicitType(rect: CGRect, checkbox: Bool, page: Int, fields: [FormEntry]) -> Bool {
        fields.contains {
            $0.page == page && ($0.widgetName != nil || $0.origin == "manual") && $0.checkbox != checkbox && overlaps($0.rect, rect)
        }
    }
    /// Migrate a model-created text duplicate on a real checkbox. Preserve any
    /// entered value in the field inspector, never print text inside the tick.
    static func repair(_ input: [FormEntry]) -> [FormEntry] {
        var fields = input
        var removed = Set<UUID>()
        for index in fields.indices where fields[index].checkbox {
            let anchor = fields[index]
            for candidate in input where candidate.id != anchor.id && candidate.page == anchor.page && !candidate.checkbox && candidate.widgetName == nil && candidate.origin == "model" {
                let ratio = max(anchor.rect.area, candidate.rect.area) / max(1, min(anchor.rect.area, candidate.rect.area))
                let overlap = anchor.rect.intersection(candidate.rect).area
                let union = anchor.rect.area + candidate.rect.area - overlap
                let tight = ratio < 2 && union > 0 && overlap / union > 0.6
                guard (anchor.widgetName != nil && overlaps(anchor.rect, candidate.rect)) || tight else { continue }
                if !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let old = fields[index].recoveredText ?? ""
                    fields[index].recoveredText = old.isEmpty ? candidate.text : old + "\n" + candidate.text
                }
                removed.insert(candidate.id)
            }
        }
        fields.removeAll { removed.contains($0.id) }
        return fields
    }
}
