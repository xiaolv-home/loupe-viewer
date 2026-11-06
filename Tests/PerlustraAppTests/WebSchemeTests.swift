import Testing
@testable import PerlustraApp

@Suite("写作模式的本地资源")
struct WebSchemeTests {
    @Test("Vditor 要的 Mermaid 用应用自带的那份")
    func sharedMermaid() {
        #expect(PerlustraSchemeHandler.sharedVendorPath("/vditor/dist/js/mermaid/mermaid.min.js") == "vendor/mermaid.min.js")
    }

    @Test("Vditor 自己的文件不重定向")
    func ownFiles() {
        #expect(PerlustraSchemeHandler.sharedVendorPath("/vditor/dist/index.min.js") == "/vditor/dist/index.min.js")
    }
}
