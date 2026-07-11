import Testing

@testable import socktainer

@Suite("PullByteCounter")
struct PullByteCounterTests {

    @Test("accumulates add and set size events")
    func accumulation() async {
        let counter = PullByteCounter(emitInterval: .zero)
        let first = await counter.apply([.addTotalSize(1000), .addSize(200)])
        #expect(first?.current == 200)
        #expect(first?.total == 1000)

        let second = await counter.apply([.addSize(300), .setTotalSize(2000)])
        #expect(second?.current == 500)
        #expect(second?.total == 2000)

        let overridden = await counter.apply([.setSize(1999)])
        #expect(overridden?.current == 1999)
    }

    @Test("batches without size events emit nothing")
    func ignoresNonSizeEvents() async {
        let counter = PullByteCounter(emitInterval: .zero)
        let result = await counter.apply([.setDescription("Pulling"), .addItems(3)])
        #expect(result == nil)
    }

    @Test("rapid batches are throttled, completion always emits")
    func throttling() async {
        let counter = PullByteCounter(emitInterval: .seconds(3600))
        let first = await counter.apply([.addTotalSize(100), .addSize(10)])
        #expect(first != nil)

        let suppressed = await counter.apply([.addSize(10)])
        #expect(suppressed == nil)

        let completion = await counter.apply([.addSize(80)])
        #expect(completion?.current == 100)
        #expect(completion?.total == 100)
    }
}
