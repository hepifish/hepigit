import Foundation

/// One row of the commit graph. Lanes keep their index for their whole life,
/// so every row can be drawn independently (cheap, lazy, no global canvas).
struct GraphRow {
    var node: Int
    var hasTop: Bool          // a line arrives from above into the node lane
    var through: [Int]        // lanes that pass straight by this row
    var incoming: [Int]       // other lanes merging into the node from above
    var outgoing: [Int]       // lanes the node continues into, below
    var width: Int
}

enum GraphLayout {
    static func compute(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil); return lanes.count - 1
        }

        for c in commits {
            var hits: [Int] = []
            for (i, l) in lanes.enumerated() where l == c.id { hits.append(i) }
            let node: Int
            if let first = hits.first { node = first } else { node = freeSlot() }
            let before = lanes
            for j in hits { lanes[j] = nil }
            lanes[node] = nil

            var outgoing: [Int] = []
            for (k, p) in c.parents.enumerated() {
                if let existing = lanes.firstIndex(where: { $0 == p }) { outgoing.append(existing); continue }
                let slot = k == 0 ? node : freeSlot()
                lanes[slot] = p
                outgoing.append(slot)
            }

            var through: [Int] = []
            for (i, l) in before.enumerated() where l != nil && l != c.id { through.append(i) }
            let width = max(before.count, lanes.count, node + 1)
            while let last = lanes.last, last == nil { lanes.removeLast() }

            rows.append(GraphRow(node: node, hasTop: !hits.isEmpty, through: through,
                                 incoming: Array(hits.dropFirst()), outgoing: outgoing, width: width))
        }
        return rows
    }
}
