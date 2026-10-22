#!/usr/bin/env python3
"""Exercise production recovery actions with a deterministic clipboard stand-in.

This executes the actual Swift method bodies, including their real delayed work.
It does not verify SwiftUI identity; the signed UI fixture covers presentation reuse.
Use --revision HEAD to run against the pre-fix committed actions.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--revision")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
selected = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
developer = os.environ.get("DEVELOPER_DIR", selected)
if not (Path(developer) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to a full installed Xcode.")
os.environ["DEVELOPER_DIR"] = developer


def read_source(name):
    path = f"Sources/Fluid/Views/{name}.swift"
    if args.revision:
        return subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=repo, text=True)
    return (repo / path).read_text()


card = read_source("DeliveryFailureCard")
card_actions = card[card.index("    private func copy() {"):card.rfind("\n}")]
overlay = read_source("DeliveryFailureOverlay")
overlay_action = overlay[overlay.index("    private func copy() {"):overlay.rfind("\n}")]
swift = r'''
import Foundation
import SwiftUI

enum ClipboardService {
    static var text = "clipboard before test"
    static var calls = 0
    static var fail = false
    static func reset() { text = "clipboard before test"; calls = 0; fail = false }
    static func copyToClipboard(_ text: String) -> Bool {
        calls += 1
        guard !fail else { return false }
        self.text = text
        return true
    }
}
final class Card {
    static let autoDismissDelay: TimeInterval = 10
    var transcript = "first transcript"
    var didCopy = false
    var autoDismissWorkItem: DispatchWorkItem?
    var dismissals = 0
    var onDismiss: () -> Void { { self.dismissals += 1 } }
    CARD_ACTIONS
}
final class Popup {
    var transcript = "first transcript"
    var didCopy = false
    var successes = 0
    var onCopied: () -> Void { { self.successes += 1 } }
    OVERLAY_ACTION
}
@main struct Tests {
    static var failures = 0
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }
    static func main() async throws {
        ClipboardService.reset()
        let card = Card()
        card.copy()
        check(card.didCopy && ClipboardService.text == "first transcript", "Card first copy succeeds")
        ClipboardService.text = "unrelated clipboard content"
        card.copy()
        check(ClipboardService.text == "first transcript" && ClipboardService.calls == 2, "Card allows re-copy after clipboard changes")
        card.transcript = "second transcript"
        card.copy()
        check(ClipboardService.text == "second transcript", "Card copies its current transcript")
        ClipboardService.fail = true
        card.copy()
        check(!card.didCopy, "Card clears success after a failed write")
        check(card.autoDismissWorkItem != nil, "Failed card copy retains a bounded dismiss timer")
        ClipboardService.fail = false
        card.copy()
        check(card.didCopy && ClipboardService.text == "second transcript", "Card can retry after failure")
        card.cancelAutoDismiss()

        ClipboardService.reset()
        ClipboardService.fail = true
        let failedCard = Card()
        failedCard.copy()
        check(!failedCard.didCopy, "Fresh failed card must not say Copied")
        check(ClipboardService.text == "clipboard before test", "Failed card copy must not replace clipboard")
        ClipboardService.fail = false
        failedCard.copy()
        check(failedCard.didCopy, "Fresh failed card remains retryable")
        failedCard.cancelAutoDismiss()

        ClipboardService.reset()
        let disappearingCard = Card()
        disappearingCard.copy()
        let cancelledWork = disappearingCard.autoDismissWorkItem
        disappearingCard.cancelAutoDismiss()
        check(cancelledWork?.isCancelled == true, "Disappearing card cancels copied-dismiss work")

        let changingCard = Card()
        changingCard.copy()
        let oldWork = changingCard.autoDismissWorkItem
        changingCard.didCopy = false
        changingCard.transcript = "new failure"
        changingCard.scheduleAutoDismiss()
        check(oldWork?.isCancelled == true, "Replacing a transcript cancels copied-dismiss work")

        ClipboardService.reset()
        let popup = Popup()
        popup.copy()
        check(popup.didCopy && popup.successes == 1, "Popup first copy succeeds")
        ClipboardService.text = "unrelated clipboard content"
        popup.copy()
        check(ClipboardService.text == "first transcript" && popup.successes == 2, "Popup allows re-copy after clipboard changes")
        popup.transcript = "second transcript"
        popup.copy()
        check(ClipboardService.text == "second transcript", "Popup copies its current transcript")
        let successes = popup.successes
        ClipboardService.fail = true
        popup.copy()
        check(!popup.didCopy && popup.successes == successes, "Failed popup copy neither says Copied nor dismisses")
        ClipboardService.fail = false
        popup.copy()
        check(popup.didCopy && popup.successes == successes + 1, "Popup retry succeeds")

        ClipboardService.reset()
        ClipboardService.fail = true
        let failedPopup = Popup()
        failedPopup.copy()
        check(!failedPopup.didCopy && failedPopup.successes == 0, "Fresh failed popup must not say Copied or dismiss")
        check(ClipboardService.text == "clipboard before test", "Failed popup copy must preserve clipboard")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        check(disappearingCard.dismissals == 0, "Cancelled copy timer never dismisses after disappearance")
        check(changingCard.dismissals == 0, "Old copy timer never dismisses a replacement transcript")
        changingCard.cancelAutoDismiss()
        print("\(assertions) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''
swift = swift.replace("CARD_ACTIONS", card_actions.replace("private func ", "func "))
swift = swift.replace("OVERLAY_ACTION", overlay_action.replace("private func ", "func "))
with tempfile.TemporaryDirectory(prefix="fv-recovery-copy-") as directory:
    root = Path(directory)
    source = root / "Tests.swift"
    binary = root / "tests"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
