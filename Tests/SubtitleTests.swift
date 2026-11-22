import UIKit
import XCTest
@testable import AetherEngine
@testable import NuvioTV

final class SubtitleTests: XCTestCase {
    func testOCRPreservesInitialsAndUncertainAnnotations() {
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("- J is my name."), "- J is my name.")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("Grade J"), "Grade J")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("[sighs I can't believe it"), "[Sighs I can't believe it")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("iPhone, please"), "iPhone, please")
    }

    func testOCRRepairsGlyphsWhenTheCueContainsEvidence() {
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("J a song ♪"), "♪ A song ♪")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("♪ a song\nthat lasts j"), "♪ A song\nthat lasts ♪")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("|sighs] we should go"), "[SIGHS] We should go")
        XCTAssertEqual(SubtitleOCRCleanup.cleaned("[sighs|"), "[SIGHS]")
    }

    func testDialogueDashesGetASpaceInTextSubtitles() {
        XCTAssertEqual(
            SubtitleDialogueSpacing.spaced("-Uh, yeah, I guess so.\n-Oh, shit."),
            "- Uh, yeah, I guess so.\n- Oh, shit."
        )
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("\u{2010}Uh.\n\u{2011}Oh."), "\u{2010} Uh.\n\u{2011} Oh.")
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("Yeah? -No."), "Yeah? - No.")
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("[sighs] -What?"), "[sighs] - What?")
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("- Already spaced."), "- Already spaced.")
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("-5 degrees"), "-5 degrees")
        XCTAssertEqual(SubtitleDialogueSpacing.spaced("A well-known place."), "A well-known place.")
    }

    func testOCRJoinsFragmentsInTheTrackReadingDirection() {
        let fragments = [
            (text: "right", box: CGRect(x: 0.65, y: 0.78, width: 0.2, height: 0.06)),
            (text: "bottom", box: CGRect(x: 0.1, y: 0.15, width: 0.2, height: 0.06)),
            (text: "left", box: CGRect(x: 0.12, y: 0.76, width: 0.2, height: 0.06)),
        ]
        XCTAssertEqual(SubtitleImageOCR.assembleLines(fragments, language: "en"), "left right\nbottom")
        XCTAssertEqual(SubtitleImageOCR.assembleLines(fragments, language: "ar"), "right left\nbottom")
    }

    @MainActor
    func testPlainSubtitleRendererPreservesAuthoredText() {
        let appearance = SubtitleTextAppearance(
            fontSize: 32, bold: false, color: .white, opacity: 1,
            outlineColor: .black, outlineWidth: 2, kerning: 0, alignment: .center
        )
        let text = "iPhone, please.\nhere? [sighs]"
        XCTAssertEqual(SubtitleAttributedText.make(plain: text, appearance: appearance).string, text)
    }
}
