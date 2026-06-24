import Testing
@testable import CodexKit

@Test func productNameIdentifiesCoreModule() {
    #expect(CodexKit.productName == "CodexKit")
}
