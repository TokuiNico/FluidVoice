import AppKit
import Combine
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class OverlayCaptionPresentationTests: XCTestCase {
    func testRetainedVisibleLineUpdatesWhenTheShortPreviewIsUnchanged() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        func drawnLines(_ text: String) async throws -> [Data] {
            view.update(caption: .tail(text, limit: 50), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: true)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 304,
                pixelsHigh: 54,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            return (0..<3).map { line in
                Data(bytes: pixels.advanced(by: line * 18 * bitmap.bytesPerRow), count: 18 * bitmap.bytesPerRow)
            }
        }
        let original = "The old word sits on line one.\nThe second line is unchanged.\nThe last line is unchanged."
        let corrected = original.replacingOccurrences(of: "old", with: "new")
        XCTAssertEqual(OverlayCaptionText.tail(original, limit: 50), .tail(corrected, limit: 50))
        let before = try await drawnLines(original)
        let after = try await drawnLines(corrected)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 1, "Redraw the corrected visible line while preserving both unchanged lines")
        XCTAssertEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(corrected, limit: 50).text)
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true)
    }

    func testWordsAppearInStepsWithACompositorFade() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        let phrase = "Words gently flow into place instead of arriving as a whole pasted chunk."
        view.update(caption: .tail(phrase, limit: 100), fontSize: 13, opacity: 1, reduceMotion: false)
        view.layoutSubtreeIfNeeded()
        let initial = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertFalse(initial.isEmpty)
        XCTAssertTrue(phrase.hasPrefix(initial))
        XCTAssertNotEqual(initial, phrase)
        let fade = try XCTUnwrap(view.layer?.sublayers?.last)
        XCTAssertEqual(try XCTUnwrap(fade.animation(forKey: "captionReveal")).duration, OverlayCaptionNSView.revealDuration)
        try await Task.sleep(for: .milliseconds(35))
        let opacity = try XCTUnwrap(fade.presentation()).opacity
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThan(opacity, 1, "New words must actually fade, not just change the text snapshot")
        try await Task.sleep(for: .milliseconds(75))
        let intermediate = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertGreaterThan(intermediate.count, initial.count)
        XCTAssertLessThan(intermediate.count, phrase.count)
        try await Task.sleep(for: .milliseconds(480))
        XCTAssertEqual(view.accessibilityValue() as? String, phrase)
        XCTAssertTrue(fade.animationKeys()?.isEmpty ?? true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
        let ink = (0..<54).reduce(0) { count, y in
            count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
        }
        XCTAssertGreaterThan(ink, 400, "Both the settled prefix and the final faded word must remain drawn")
        if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUTPUT"] {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("word-reveal-settled.png"))
        }
    }

    func testBufferedRevisionKeepsThreeDrawnLinesAndCancelsOnClear() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.stopScrolling(); window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String) {
            view.update(caption: .tail(text, limit: 50), context: .tail(text, limit: 800), fontSize: 13, opacity: 1, reduceMotion: false)
        }
        let original = "Earlier complete lines stay readable. The latest words may be corrected as the recognizer hears more speech."
        update(original)
        view.flushPendingCaption()
        view.layoutSubtreeIfNeeded()
        let revision = original + " A much larger chunk arrives together with enough new words to replace the entire short preview."
        update(revision + " provisional")
        update(revision)
        XCTAssertNotEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(revision, limit: 50).text)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.accessibilityValue() as? String, OverlayCaptionText.tail(revision, limit: 50).text)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: graphics.cgContext)
        for line in 0..<3 {
            let ink = (line * 18..<(line + 1) * 18).reduce(0) { count, y in
                count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            XCTAssertGreaterThan(ink, 40, "A large revision must preserve all three drawn lines")
        }
        update(revision + " first")
        update(revision + " stale pending result")
        update("")
        update("New recording")
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(view.accessibilityValue() as? String, "New recording")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
    }

    func testVisibleLinesSurviveTrimmingAndScrollingFinishesOnTime() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 304, height: 54))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String, reduceMotion: Bool = false) {
            view.update(caption: .tail(text, limit: 50), fontSize: 13, opacity: 1, reduceMotion: reduceMotion)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        var text = ""
        for word in String(repeating: "Every visible line stays readable as the preview limit advances through the sentence. ", count: 5).split(separator: " ") {
            text += "\(word) "
            update(text, reduceMotion: true)
        }
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 304,
            pixelsHigh: 54,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        try XCTUnwrap(view.layer?.presentation()).render(in: context.cgContext)
        for line in 0..<3 {
            let ink = (line * 18..<(line + 1) * 18).reduce(0) { count, y in
                count + (0..<304).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
            }
            XCTAssertGreaterThan(ink, 40, "Trimming must keep all three visible lines drawn")
        }
        update("")
        let prefix = "First sentence.\nSecond sentence.\nThird sentence."
        update(prefix)
        try await Task.sleep(for: .milliseconds(50))
        update(prefix + "\nNext")
        let begin = try XCTUnwrap(view.layer?.animation(forKey: "captionScroll")).beginTime
        try await Task.sleep(for: .milliseconds(60))
        update(prefix + "\nNext word at a time")
        XCTAssertEqual(try XCTUnwrap(view.layer?.animation(forKey: "captionScroll")).beginTime, begin)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true, "Same-line words must not prolong scrolling")
        XCTAssertEqual(
            try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42,
            try XCTUnwrap(view.layer).sublayerTransform.m42,
            accuracy: 0.5
        )
    }

    func testScrollInterpolatesThenStopsAndHonorsReduceMotion() async throws {
        let view = OverlayCaptionNSView(frame: CGRect(x: 0, y: 0, width: 180, height: 32))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ text: String, reduceMotion: Bool = false) {
            view.update(caption: .tail(text, limit: 100), fontSize: 13, opacity: 1, reduceMotion: reduceMotion)
            view.flushPendingCaption()
            view.layoutSubtreeIfNeeded()
        }
        update("First line\nSecond line")
        try await Task.sleep(for: .milliseconds(50))
        let start = try XCTUnwrap(view.layer).sublayerTransform.m42
        update("First line\nSecond line\nThird")
        let target = try XCTUnwrap(view.layer).sublayerTransform.m42
        try await Task.sleep(for: .milliseconds(60))
        let intermediate = try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42
        XCTAssertLessThan(intermediate, start)
        XCTAssertGreaterThan(intermediate, target)
        update("First line\nSecond line\nThird word")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, target)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(view.layer?.presentation()).sublayerTransform.m42, target, accuracy: 0.5)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true)
        update("First line\nSecond line\nThird word\nFourth", reduceMotion: true)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true)
        view.frame.size.height = 16
        update("First line\nSecond line\nThird word\nFourth\nFifth\nLatest caption", reduceMotion: true)
        try await Task.sleep(for: .milliseconds(50))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 180,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        // Read the compositor's already-rendered contents; forcing NSView.draw here would
        // hide the regression where AppKit culled the offscreen lines before scrolling.
        try XCTUnwrap(view.layer?.presentation()).render(in: context.cgContext)
        let inkPixels = (0..<16).reduce(0) { count, y in
            count + (0..<180).filter { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.1 }.count
        }
        XCTAssertGreaterThan(inkPixels, 40, "The latest line must remain drawn after older lines scroll out")
        update("")
        XCTAssertEqual(view.layer?.sublayerTransform.m42, 0)
    }

    func testWindowAndControlsStayStillThroughWrappingAndCorrections() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let previousText = state.transcriptionText
        let controller = BottomOverlayWindowController.shared
        defer {
            controller.hideImmediately()
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
            state.updateTranscription(previousText)
        }
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        state.updateTranscription("")
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        try await Task.sleep(for: .milliseconds(350))
        let initial = try XCTUnwrap(controller.windowSizeForTests)
        XCTAssertEqual(initial.height, 114, accuracy: 1, "Keep all three caption lines while removing excess outer padding")
        for text in ["Short", String(repeating: "W", count: 34), String(repeating: "A full caption with three visible lines. ", count: 6), "A short correction", ""] {
            state.updateTranscription(text)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(try XCTUnwrap(controller.windowSizeForTests), initial, "Text updates must not resize the overlay")
        }
    }

    func testHiddenBottomOverlayStopsPendingWordsWithoutClearingTheTranscript() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let previousText = state.transcriptionText
        let previousProcessing = state.isProcessing
        let controller = BottomOverlayWindowController.shared
        defer {
            controller.hideImmediately()
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
            state.updateTranscription(previousText)
            state.isProcessing = previousProcessing
        }
        func caption(in view: NSView) -> OverlayCaptionNSView? {
            if let caption = view as? OverlayCaptionNSView { return caption }
            return view.subviews.lazy.compactMap { caption(in: $0) }.first
        }
        settings.overlaySize = .medium
        settings.enableStreamingPreview = true
        state.isProcessing = false
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        let text = "The hidden preview must stop revealing this long sentence while preserving the transcript for the next action."
        state.updateTranscription(text)
        try await Task.sleep(for: .milliseconds(35))
        let host = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView as? NSHostingView<BottomOverlayView> }.first)
        let view = try XCTUnwrap(caption(in: host))
        XCTAssertNotEqual(view.accessibilityValue() as? String, state.cachedPreviewText)
        controller.hideImmediately()
        for _ in 0..<30 where state.isBottomOverlayPresented {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isBottomOverlayPresented)
        host.layoutSubtreeIfNeeded()
        let hiddenValue = view.accessibilityValue() as? String
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.accessibilityValue() as? String, hiddenValue)
        XCTAssertEqual(state.transcriptionText, text)
        XCTAssertTrue(view.layer?.sublayers?.allSatisfy { $0.animationKeys()?.isEmpty != false } == true)
        controller.show(audioPublisher: Just(CGFloat.zero).eraseToAnyPublisher(), mode: .dictation)
        state.updateTranscription("Fresh words after reopening")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try XCTUnwrap(caption(in: host)).accessibilityValue() as? String, "Fresh words after reopening")
    }

    func testPreviewTracksItsPositionWithoutChangingRecordingState() {
        let state = NotchContentState.shared
        let settings = SettingsStore.shared
        let previousLimit = settings.transcriptionPreviewCharLimit
        let previousText = state.transcriptionText
        let mode = state.mode
        let processing = state.isProcessing
        let muted = state.isDictationMuted
        let target = state.recordingTargetPID
        let commandOutput = state.commandOutput
        defer {
            settings.transcriptionPreviewCharLimit = previousLimit
            state.updateTranscription(previousText)
        }
        settings.transcriptionPreviewCharLimit = 100
        let source = String(repeating: "Captions stay readable while the user keeps speaking. 👩🏽‍💻 ", count: 100)
        state.updateTranscription(source)
        XCTAssertEqual(state.captionPreview, OverlayCaptionText.tail(source, limit: 100))
        XCTAssertEqual(state.transcriptionText.count, 800)
        state.updateTranscription(source + "New words")
        XCTAssertEqual(state.captionPreview, OverlayCaptionText.tail(source + "New words", limit: 100))
        state.updateTranscription("")
        XCTAssertEqual(state.captionPreview, .empty)
        XCTAssertEqual(state.mode, mode)
        XCTAssertEqual(state.isProcessing, processing)
        XCTAssertEqual(state.isDictationMuted, muted)
        XCTAssertEqual(state.recordingTargetPID, target)
        XCTAssertEqual(state.commandOutput, commandOutput)
    }

    func testCaptionSurfaces() async throws {
        let settings = SettingsStore.shared
        let state = NotchContentState.shared
        let previousSize = settings.overlaySize
        let previousPreview = settings.enableStreamingPreview
        let previousLimit = settings.transcriptionPreviewCharLimit
        let previousText = state.transcriptionText
        let previousProcessing = state.isProcessing
        let previousMode = state.mode
        let previousExpanded = state.isRecordingInExpandedMode
        let previousPresented = state.isBottomOverlayPresented
        defer {
            settings.overlaySize = previousSize
            settings.enableStreamingPreview = previousPreview
            settings.transcriptionPreviewCharLimit = previousLimit
            state.updateTranscription(previousText)
            state.isProcessing = previousProcessing
            state.mode = previousMode
            state.isRecordingInExpandedMode = previousExpanded
            state.setBottomOverlayPresented(previousPresented)
        }
        settings.enableStreamingPreview = true
        settings.transcriptionPreviewCharLimit = 100
        state.isProcessing = false
        state.mode = .dictation
        state.isRecordingInExpandedMode = true
        state.setBottomOverlayPresented(true)
        let review = ProcessInfo.processInfo.environment["FLUIDVOICE_CAPTION_REVIEW"] == "1"
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Caption scrolling review"
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let words = ("The caption should stay easy to follow while new words arrive. " +
            "Each complete line moves upward smoothly, keeping the rest of the sentence in place. " +
            "A correction changes the words without making the entire overlay jump. " +
            "This sentence continues beyond the preview limit so we can check that wrapping stays stable throughout a longer recording.").split(separator: " ")
        let audio = Just(CGFloat.zero).eraseToAnyPublisher()
        for size in [SettingsStore.OverlaySize.small, .medium, .large] {
            settings.overlaySize = size
            state.updateTranscription("")
            let host = NSHostingView(rootView: VStack(spacing: 22) {
                Text("\(size.rawValue.capitalized) · top notch / compact notch / bottom overlay").foregroundStyle(.white)
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 18) {
                        NotchExpandedView(audioPublisher: audio)
                        NotchCompactBottomView().background(.black)
                    }.frame(width: 290)
                    BottomOverlayView()
                }
                NotchCommandOutputExpandedView(audioPublisher: audio, onDismiss: {}, onSubmit: { _ in false }, onNewChat: {}, onSwitchChat: { _ in }, onClearChat: {})
                    .frame(width: 600)
            }
            .padding(24)
            .frame(width: 1000, height: 680)
            .background(Color(white: 0.12))
            .appTheme(.dark))
            window.contentView = host
            if review { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            for index in stride(from: 0, to: words.count, by: review ? 3 : 1) {
                let latest = words[...min(index + (review ? 2 : 0), words.count - 1)].joined(separator: " ")
                state.updateTranscription(latest)
                if review, index % 9 == 0 {
                    // A revised partial followed by its correction inside one display interval.
                    state.updateTranscription(latest + " provisional")
                    state.updateTranscription(latest)
                }
                try await Task.sleep(for: .milliseconds(review ? 450 : 1))
            }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.width, 1000)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "caption-\(size.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let output = ProcessInfo.processInfo.environment["CAPTION_TEST_OUTPUT"] {
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("surface-\(size.rawValue).png"))
            }
            if review { try await Task.sleep(for: .seconds(3)) }
        }
    }
}
