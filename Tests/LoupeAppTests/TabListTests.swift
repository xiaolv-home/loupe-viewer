import Foundation
import Testing

@testable import LoupeApp

@MainActor
@Suite("标签栏")
struct TabListTests {
    private func list(_ count: Int, width: CGFloat = 1000) -> (TabList, [ViewerModel]) {
        let docs = (0..<count).map { _ in ViewerModel() }
        let tabs = TabList(first: docs[0])
        for (i, d) in docs.enumerated().dropFirst() { tabs.insert(d, after: docs[i - 1]) }
        tabs.availableWidth = width
        return (tabs, docs)
    }

    @Test("拖过半个标签才交换位置")
    func tradesPastHalfway() {
        let (tabs, d) = list(3)
        var shift: CGFloat = 0
        #expect(tabs.reorder(d[0], translation: 40, shift: &shift, step: 100) == 40)
        #expect(tabs.docs[0] === d[0])
        #expect(tabs.reorder(d[0], translation: 60, shift: &shift, step: 100) == -40)
        #expect(tabs.docs[1] === d[0])
        #expect(shift == 100)
    }

    @Test("一次拖很远能连续交换，到头为止")
    func stopsAtEnds() {
        let (tabs, d) = list(3)
        var shift: CGFloat = 0
        _ = tabs.reorder(d[0], translation: 900, shift: &shift, step: 100)
        #expect(tabs.docs.last === d[0])
        #expect(shift == 200)
        _ = tabs.reorder(d[0], translation: -900, shift: &shift, step: 100)
        #expect(tabs.docs.first === d[0])
    }

    @Test("标签少时不撑满，放不下时压窄")
    func widths() {
        #expect(list(2).0.chipWidth == TabList.chipMax)
        let crowded = list(12, width: 800).0
        #expect(crowded.chipWidth < TabList.chipMax)
        #expect(crowded.chipWidth >= TabList.chipMin)
    }

    @Test("放不下时当前标签始终在可见范围内")
    func keepsCurrentInView() {
        let (tabs, d) = list(30, width: 500)
        #expect(tabs.contentWidth > tabs.visibleWidth)
        for doc in [d[0], d[15], d[29]] {
            tabs.select(doc)
            let i = CGFloat(tabs.docs.firstIndex { $0 === doc } ?? 0)
            let left = i * (tabs.chipWidth + TabList.gap) - tabs.scrollOffset
            #expect(left >= 0)
            #expect(left + tabs.chipWidth <= tabs.visibleWidth)
        }
    }

    @Test("关掉后显示右边的，最右边的显示左边的")
    func neighbour() {
        let (tabs, d) = list(3)
        #expect(tabs.neighbour(of: d[1]) === d[2])
        #expect(tabs.neighbour(of: d[2]) === d[1])
    }
}
