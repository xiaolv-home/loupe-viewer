import Foundation
import Testing

@testable import LoupeApp

@Suite struct HomePageTests {
    /// The canvas draws only while something moves, so every motion has to end.
    @Test func springComesToRest() {
        var spring = SpringValue(SIMD2(0, 0))
        spring.target = SIMD2(400, -120)
        #expect(!spring.isSettled(within: 0.02))
        var frames = 0
        while !spring.isSettled(within: 0.02) && frames < 1000 {
            spring.step(by: 1.0 / 60, stiffness: 8)
            frames += 1
        }
        #expect(frames < 300)
    }

    @Test func springNeverOvershootsFromRest() {
        var spring = SpringValue(SIMD2(0, 0))
        spring.target = SIMD2(100, 0)
        for _ in 0..<600 {
            spring.step(by: 1.0 / 20, stiffness: 24)
            #expect(spring.value.x <= 100.001)
        }
    }

    @Test func loupeRestsOnTheLinesAndClearOfTheTitle() {
        for (width, height, title) in [(Float(1000), Float(291), Float(310)), (1500, 480, 460), (604, 280, 240)] {
            let layout = GuillocheLayout(width: width, height: height, titleEnd: title)
            #expect(layout.lensRest.x - layout.lensRadius > title)
            #expect(layout.lensRest.x + layout.lensRadius < width)
            #expect(layout.lensRest.y > 0 && layout.lensRest.y < height)
        }
    }

    @Test func pointerCannotPushTheLoupeOutOfTheCanvas() {
        let layout = GuillocheLayout(width: 1000, height: 291, titleEnd: 310)
        let corner = layout.lensPosition(forPointer: SIMD2(5000, -300))
        #expect(corner.x + layout.lensRadius < 1000)
        #expect(corner.y - layout.lensRadius > 0)
        let left = layout.lensPosition(forPointer: SIMD2(0, 150))
        #expect(left.x >= layout.reachStart)
    }

    @Test func filterNeedsEveryWordInNameOrFolder() {
        let files = ["/a/工作/周报.xlsx", "/a/工作/月报.pdf", "/b/Photos/IMG.HEIC"].map { RecentFile(url: URL(fileURLWithPath: $0), modified: nil) }
        #expect(RecentFiles.matching(files, query: "").count == 3)
        #expect(RecentFiles.matching(files, query: "  ").count == 3)
        #expect(RecentFiles.matching(files, query: "工作").count == 2)
        #expect(RecentFiles.matching(files, query: "工作 周报").map(\.name) == ["周报.xlsx"])
        #expect(RecentFiles.matching(files, query: "img").map(\.name) == ["IMG.HEIC"])
        #expect(RecentFiles.matching(files, query: "没有").isEmpty)
    }

    @Test func timeLabelIsAsShortAsItCanBe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 5) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = at(2026, 11, 6, 15, 0)
        #expect(RecentFile.timeLabel(at(2026, 11, 6), now: now, calendar: calendar) == "今天 09:05")
        #expect(RecentFile.timeLabel(at(2026, 11, 5), now: now, calendar: calendar) == "昨天 09:05")
        #expect(RecentFile.timeLabel(at(2026, 3, 2), now: now, calendar: calendar) == "3月2日")
        #expect(RecentFile.timeLabel(at(2025, 12, 31), now: now, calendar: calendar) == "2025年12月31日")
    }
}
