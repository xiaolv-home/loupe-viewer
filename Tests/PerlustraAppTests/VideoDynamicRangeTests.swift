import Testing

@testable import PerlustraApp

@Suite("视频动态范围")
struct VideoDynamicRangeTests {
    @Test("名称和是否 HDR")
    func names() {
        #expect(VideoDynamicRange(kind: .dolbyVision).isHDR)
        #expect(VideoDynamicRange(kind: .hlg, bitDepth: 10).detail == "HDR（HLG） · 10 bit")
        #expect(!VideoDynamicRange(kind: .sdr).isHDR)
    }
}
