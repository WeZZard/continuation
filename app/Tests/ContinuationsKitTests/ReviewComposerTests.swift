import Foundation
import XCTest
@testable import ContinuationsKit

final class ReviewComposerTests: XCTestCase {

    func testAMessageWithoutAttachmentsIsJustTheMessage() {
        XCTAssertEqual(ReviewComposer.message(text: "  run the tests  ",
                                              attachments: []),
                       "run the tests")
    }

    func testAnImageTravelsAsAPathTheAgentCanOpen() {
        // The channel back into a session carries text, so the image is
        // named rather than embedded.
        let shot = URL(fileURLWithPath: "/tmp/shots/screen.png")
        let composed = ReviewComposer.message(text: "look at this",
                                              attachments: [shot])
        XCTAssertTrue(composed.hasPrefix("look at this\n\n"))
        XCTAssertTrue(composed.contains("attached an image"))
        XCTAssertTrue(composed.contains("- /tmp/shots/screen.png"))
    }

    func testImagesAloneStillMakeAMessage() {
        let composed = ReviewComposer.message(
            text: "   ",
            attachments: [URL(fileURLWithPath: "/tmp/a.png"),
                          URL(fileURLWithPath: "/tmp/b.jpg")])
        XCTAssertTrue(composed.hasPrefix("The user attached 2 images"))
        XCTAssertTrue(composed.contains("- /tmp/a.png"))
        XCTAssertTrue(composed.contains("- /tmp/b.jpg"))
    }

    func testOnlyImagesAreAccepted() {
        XCTAssertTrue(ReviewComposer.isImage(URL(fileURLWithPath: "/a/b.PNG")))
        XCTAssertTrue(ReviewComposer.isImage(URL(fileURLWithPath: "/a/b.heic")))
        XCTAssertFalse(ReviewComposer.isImage(URL(fileURLWithPath: "/a/b.pdf")))
        XCTAssertFalse(ReviewComposer.isImage(URL(fileURLWithPath: "/a/b")))
    }

    func testADroppedFileIsCopiedSomewhereItSurvives() throws {
        // A screenshot arrives from a folder that does not last, so the
        // console keeps its own copy before naming it to the session.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("Screenshot 1.png")
        try Data("not really a png".utf8).write(to: source)

        let kept = try ReviewComposer.keep(source, in: scratch
            .appendingPathComponent("kept"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(kept.pathExtension, "png")

        // The original can go; the copy stays.
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))

        // A second drop of the same name does not overwrite the first.
        try Data("second".utf8).write(to: source)
        let again = try ReviewComposer.keep(source, in: scratch
            .appendingPathComponent("kept"))
        XCTAssertNotEqual(kept, again)
        try? FileManager.default.removeItem(at: scratch)
    }
}

extension ReviewComposerTests {

    func testADropCarryingPixelsIsKeptToo() throws {
        // An image dragged out of a browser has no path to copy from.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixels-\(UUID().uuidString)")
        let kept = try ReviewComposer.keep(data: Data("pixels".utf8),
                                           extension: "png", in: scratch)
        XCTAssertEqual(kept.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: kept), Data("pixels".utf8))
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAnUntypedDropStillLandsAsAnImage() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixels-\(UUID().uuidString)")
        let kept = try ReviewComposer.keep(data: Data("pixels".utf8),
                                           extension: "", in: scratch)
        XCTAssertEqual(kept.pathExtension, "png")
        try? FileManager.default.removeItem(at: scratch)
    }
}
