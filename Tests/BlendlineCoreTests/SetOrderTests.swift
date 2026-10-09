import Foundation
import Testing
@testable import BlendlineCore

@Suite struct SetOrderTests {
    private func key(_ text: String) -> CamelotKey { CamelotKey(parsing: text)! }
    private func item(_ key: String?, _ energy: Int?, _ bpm: Double? = nil) -> SetOrder.Item {
        SetOrder.Item(key: key.map(self.key), energy: energy, bpm: bpm)
    }
    private func order(_ items: [SetOrder.Item], by criterion: SetOrder.Criterion, after previous: SetOrder.Item? = nil) -> [Int] {
        SetOrder.order(items, by: criterion, after: previous, peakPosition: 0.7)
    }

    @Test func measuresKeyDistanceAroundTheWheel() {
        #expect(SetOrder.keyDistance(key("8A"), key("8A")) == 0)
        #expect(SetOrder.keyDistance(key("8A"), key("8B")) == 1)
        #expect(SetOrder.keyDistance(key("12A"), key("1A")) == 1)
        #expect(SetOrder.keyDistance(key("8A"), key("9B")) == 2)
        #expect(SetOrder.keyDistance(key("2A"), key("8B")) == 7)
    }

    @Test func sortsByEnergyAndTempoKeepingTiesAndUnknownsInOrder() {
        let items = [item("1A", 7, 126), item("1A", nil, 120), item("1A", 3, nil), item("1A", 7, 124), item("1A", 5, 122)]
        #expect(order(items, by: .energy) == [2, 4, 0, 3, 1])
        #expect(order(items, by: .energyDescending) == [0, 3, 4, 2, 1])
        #expect(order(items, by: .bpm) == [1, 4, 3, 0, 2])
    }

    @Test func walksTheWheelFromThePreviousKey() {
        let items = [item("9A", 5), item("8B", 5), item("3A", 5), item(nil, 5), item("9B", 5), item("8A", 5)]
        #expect(order(items, by: .key, after: item("8A", 5)) == [5, 1, 4, 0, 2, 3])
        #expect(order(items, by: .key) == [0, 4, 1, 5, 2, 3])
    }

    @Test func setCurvePeaksAtThePeakPositionAndCloses() {
        let energies = [4, 9, 5, 7, 6, 8, 3, 6, 5, 7]
        let items = energies.map { item("8A", $0, 124) }
        let ordered = order(items, by: .setCurve).map { energies[$0] }

        #expect(Set(order(items, by: .setCurve)).count == items.count)
        #expect(ordered.first == 3)
        #expect(ordered.firstIndex(of: 9) == 6)  // 70% of the way through ten tracks
        #expect(Array(ordered[...6]) == ordered[...6].sorted())
        #expect(ordered.last! < 9 && ordered.last! > 3)
    }

    @Test func setCurvePrefersHarmonicNeighboursAmongEqualEnergies() {
        let items = [item("3B", 6), item("8A", 6), item("10A", 6), item("9A", 6)]
        let ordered = order(items, by: .setCurve, after: item("8A", 6)).map { items[$0].key!.description }
        #expect(ordered == ["8A", "9A", "10A", "3B"])
    }

    @Test func setCurveLeavesTracksWithoutKeyOrEnergyLast() {
        let items = [item(nil, 8), item("1A", 4), item("1A", nil), item("1A", 6)]
        #expect(order(items, by: .setCurve) == [1, 3, 0, 2])
    }
}
