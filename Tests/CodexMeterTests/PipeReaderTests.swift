import Darwin
import Foundation
import Testing
@testable import CodexMeter

@Suite("App-server pipe reading")
struct PipeReaderTests {
    @Test("Returns currently available bytes without waiting for EOF")
    func readsPartialOpenPipe() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(Darwin.pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer {
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
        }

        let message = Data("one JSON line\n".utf8)
        let writtenCount = message.withUnsafeBytes { buffer in
            Darwin.write(writeDescriptor, buffer.baseAddress, buffer.count)
        }
        #expect(writtenCount == message.count)

        let received = try PipeReader.readAvailableBytes(
            from: readDescriptor,
            maximumCount: 16_384
        )

        #expect(received == message)
    }
}
