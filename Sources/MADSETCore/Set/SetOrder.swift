import Foundation

/// Orders tracks of a set by energy, key, tempo, or along the set's energy curve.
public enum SetOrder {
    public enum Criterion: String, CaseIterable, Sendable {
        case setCurve
        case energy
        case energyDescending
        case key
        case bpm
    }

    /// What ordering looks at in a track. Nil values are unknown.
    public struct Item: Sendable, Equatable {
        public let key: CamelotKey?
        public let energy: Int?
        public let bpm: Double?

        public init(key: CamelotKey?, energy: Int?, bpm: Double?) {
            self.key = key
            self.energy = energy
            self.bpm = bpm
        }
    }

    /// Cost of a key change by Camelot distance: up to one step mixes harmonically, two is an
    /// energy jump, more clashes.
    static func keyCost(_ distance: Int) -> Double {
        distance <= 1 ? Double(distance) / 2 : 2 * Double(distance - 1)
    }

    /// Cost of one BPM of tempo change: every track is stretched to the set tempo, so it matters
    /// far less than key or energy.
    static let bpmCostPerBeat = 0.25
    /// Energy the set closes at, as a fraction of the way from its lowest to its highest energy.
    static let closingEnergy = 0.5

    /// The order of `items` by `criterion`, as indices into `items`. `previous` is the track the
    /// ordered ones follow, if any. Items missing what the criterion needs go last, in their order.
    /// `peakPosition` is where the set curve peaks, as a fraction of the way through the items.
    public static func order(_ items: [Item], by criterion: Criterion, after previous: Item?, peakPosition: Double) -> [Int] {
        precondition((0...1).contains(peakPosition), "Peak position must be within the set: \(peakPosition)")
        let known = items.indices.filter { isKnown(items[$0], for: criterion) }
        let unknown = items.indices.filter { !isKnown(items[$0], for: criterion) }
        let ordered: [Int]
        switch criterion {
        case .energy: ordered = known.sorted { (items[$0].energy!, $0) < (items[$1].energy!, $1) }
        case .energyDescending: ordered = known.sorted { (-items[$0].energy!, $0) < (-items[$1].energy!, $1) }
        case .bpm: ordered = known.sorted { (items[$0].bpm!, $0) < (items[$1].bpm!, $1) }
        case .key: ordered = keyWalk(known, items: items, from: previous?.key)
        case .setCurve: ordered = curve(known, items: items, after: previous, peakPosition: peakPosition)
        }
        return ordered + unknown
    }

    private static func isKnown(_ item: Item, for criterion: Criterion) -> Bool {
        switch criterion {
        case .energy, .energyDescending: item.energy != nil
        case .key: item.key != nil
        case .bpm: item.bpm != nil
        case .setCurve: item.key != nil && item.energy != nil
        }
    }

    /// Steps between two keys on the Camelot wheel: around the wheel, plus one to change mode.
    public static func keyDistance(_ a: CamelotKey, _ b: CamelotKey) -> Int {
        let around = abs(a.number - b.number)
        return min(around, 12 - around) + (a.mode == b.mode ? 0 : 1)
    }

    /// Steps clockwise from `a`'s number to `b`'s.
    private static func clockwise(_ a: CamelotKey, _ b: CamelotKey) -> Int { (b.number - a.number + 12) % 12 }

    /// Walks the wheel from `start` (or the first item's key): always to the nearest key left,
    /// clockwise first, so equal keys stay together and the set climbs the wheel.
    private static func keyWalk(_ indices: [Int], items: [Item], from start: CamelotKey?) -> [Int] {
        var left = indices
        var result: [Int] = []
        var current = start ?? left.first.flatMap { items[$0].key }
        while let here = current, !left.isEmpty {
            let next = left.indices.min { i, j in
                let a = items[left[i]].key!, b = items[left[j]].key!
                return (keyDistance(here, a), clockwise(here, a), left[i]) < (keyDistance(here, b), clockwise(here, b), left[j])
            }!
            result.append(left.remove(at: next))
            current = items[result.last!].key
        }
        return result
    }

    /// Energy the set curve asks for at `position` (0...1): rising from `low` to `high` at
    /// `peakPosition`, then falling to the closing energy.
    static func targetEnergy(at position: Double, low: Double, high: Double, peakPosition: Double) -> Double {
        let closing = low + (high - low) * closingEnergy
        if position <= peakPosition {
            return peakPosition == 0 ? high : low + (high - low) * position / peakPosition
        }
        return high + (closing - high) * (position - peakPosition) / (1 - peakPosition)
    }

    /// The order with the lowest cost: distance from the energy curve at every position, plus the
    /// key and tempo change into every track. Starts from energies matched rank by rank to the
    /// curve, then swaps tracks and reverses runs while that lowers the cost.
    private static func curve(_ indices: [Int], items: [Item], after previous: Item?, peakPosition: Double) -> [Int] {
        guard indices.count > 1 else { return indices }
        let energies = indices.map { Double(items[$0].energy!) }
        let targets = indices.indices.map {
            targetEnergy(at: Double($0) / Double(indices.count - 1), low: energies.min()!, high: energies.max()!, peakPosition: peakPosition)
        }

        func transition(_ from: Item, _ to: Item) -> Double {
            var cost = keyCost(keyDistance(from.key!, to.key!))
            if let a = from.bpm, let b = to.bpm { cost += abs(a - b) * bpmCostPerBeat }
            return cost
        }
        func cost(_ order: [Int]) -> Double {
            var total = 0.0
            for (position, index) in order.enumerated() {
                total += abs(Double(items[index].energy!) - targets[position])
                if position > 0 {
                    total += transition(items[order[position - 1]], items[index])
                } else if let previous, previous.key != nil {
                    total += transition(previous, items[index])
                }
            }
            return total
        }

        let byEnergy = indices.sorted { (items[$0].energy!, $0) < (items[$1].energy!, $1) }
        let slots = targets.indices.sorted { (targets[$0], $0) < (targets[$1], $1) }
        var order = indices
        for (rank, slot) in slots.enumerated() { order[slot] = byEnergy[rank] }

        var best = cost(order)
        var improved = true
        while improved {
            improved = false
            for i in order.indices {
                for j in order.indices where j > i {
                    for reverses in [false, true] {
                        var candidate = order
                        if reverses { candidate[i...j].reverse() } else { candidate.swapAt(i, j) }
                        let candidateCost = cost(candidate)
                        if candidateCost < best - 1e-9 {
                            order = candidate
                            best = candidateCost
                            improved = true
                        }
                    }
                }
            }
        }
        return order
    }
}
