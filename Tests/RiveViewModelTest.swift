//
//  RiveViewModelTest.swift
//  RiveRuntimeTests
//
//  Created by Maxwell Talbot on 14/02/2023.
//  Copyright © 2023 Rive. All rights reserved.
//

import XCTest
import RiveRuntime
#if canImport(UIKit)
import UIKit
#endif

class RiveViewModelTest: XCTestCase {
    
    // This test reproduces a previous production error
    // Having an Animation state without an animation caused advancing a state machine past it
    // to fail
    func testLoadFileWithEmptyAnimationState() throws {
        let file = try RiveFile(testfileName: "empty_animation_state")
        let model = RiveModel(riveFile: file)
        let viewModel = RiveViewModel(model, autoPlay: false)
        let view = viewModel.createRiveView()
        
        view.advance(delta: 0.1)
    }
    
    func testChangingTextRun_updatesText_andAdvances() throws {
        let file = try RiveFile(testfileName: "testtext")
        let model = RiveModel(riveFile: file)
        let viewModel = RiveViewModel(model, autoPlay: false)
        let delegate = PlayerDelegate()
        let view = viewModel.createRiveView()
        view.playerDelegate = delegate

        XCTAssertEqual(viewModel.getTextRunValue("MyRun"), "Hello there")
        try viewModel.setTextRunValue("MyRun", textValue: "Hello test")
        XCTAssertEqual(viewModel.getTextRunValue("MyRun"), "Hello test")
        XCTAssertTrue(delegate.didAdvance)
    }

    func testChangingNestedTextRun_updatesText_andAdvances() throws {
        let file = try RiveFile(testfileName: "nested_text_run")
        let model = RiveModel(riveFile: file)
        let viewModel = RiveViewModel(model, autoPlay: false)
        let view = viewModel.createRiveView()
        let delegate = PlayerDelegate()
        view.playerDelegate = delegate

        XCTAssertEqual(viewModel.getTextRunValue("text", path: "Nested/Two-Deep"), "Text")
        try viewModel.setTextRunValue("text", path: "Nested/Two-Deep", textValue: "Hello test")
        XCTAssertEqual(viewModel.getTextRunValue("text", path: "Nested/Two-Deep"), "Hello test")
        XCTAssertTrue(delegate.didAdvance)
    }

#if canImport(UIKit) && WITH_RIVE_TEXT && !RIVE_MAC_CATALYST
    @MainActor
    func testTextInputAutomatic_choosesExpectedControlFromWrapAndSizing() throws {
        let file = try RiveFile(testfileName: "testtext")
        let model = RiveModel(riveFile: file)
        try model.setArtboard()

        let view = RiveView(model: model, autoPlay: false)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        guard let artboard = model.artboard else {
            XCTFail("Expected model.artboard")
            return
        }
        guard let run = artboard.textRun("MyRun") else {
            XCTFail("Expected text run \"MyRun\"")
            return
        }

        let initialText = run.text()
        let hasLineBreaks = initialText.contains("\n") || initialText.contains("\r")
        let wrap = Int(run.textWrap())
        let sizing = Int(run.textSizing())

        // Mirror runtime selection logic:
        // - multiLine if the existing text already has line breaks
        // - singleLine if wrap == noWrap or sizing == autoWidth
        // - otherwise multiLine
        let expectSingleLine = !hasLineBreaks && (wrap == 1 || sizing == 0)

        _ = try view.bindTextInput(RiveTextInputBinding(textRunName: "MyRun"))

        let control = view.subviews.first { $0 is UITextField || $0 is UITextView }
        XCTAssertNotNil(control)
        if expectSingleLine {
            XCTAssertTrue(control is UITextField)
        } else {
            XCTAssertTrue(control is UITextView)
        }
    }

    @MainActor
    func testTextInputMultiLine_autoWidth_resizesImmediatelyAfterChange() throws {
        let file = try RiveFile(testfileName: "testtext")
        let model = RiveModel(riveFile: file)
        try model.setArtboard()

        let view = RiveView(model: model, autoPlay: false)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        guard let artboard = model.artboard else {
            XCTFail("Expected model.artboard")
            return
        }
        guard let run = artboard.textRun("MyRun") else {
            XCTFail("Expected text run \"MyRun\"")
            return
        }

        guard Int(run.textSizing()) == 0 else {
            throw XCTSkip("Text run is not autoWidth; this test expects bounds to grow with text.")
        }

        var binding = RiveTextInputBinding(textRunName: "MyRun")
        binding.kind = .multiLine // force UITextView even though autoWidth behaves like single line.
        _ = try view.bindTextInput(binding)

        guard let tv = view.subviews.compactMap({ $0 as? UITextView }).first else {
            XCTFail("Expected UITextView overlay for kind == .multiLine")
            return
        }

        let initialWidth = tv.bounds.width

        // Simulate "typing" by setting text and calling the delegate callback (which forwards into Rive).
        tv.text = String(repeating: "Hello ", count: 12)
        tv.delegate?.textViewDidChange?(tv)

        XCTAssertGreaterThan(tv.bounds.width, initialWidth)
    }
#endif
}

private extension RiveViewModelTest {
    class PlayerDelegate: NSObject, RivePlayerDelegate {
        var didAdvance = false

        func player(playedWithModel riveModel: RiveRuntime.RiveModel?) { }

        func player(pausedWithModel riveModel: RiveRuntime.RiveModel?) { }

        func player(loopedWithModel riveModel: RiveRuntime.RiveModel?, type: Int) { }

        func player(stoppedWithModel riveModel: RiveRuntime.RiveModel?) { }

        func player(didAdvanceby seconds: Double, riveModel: RiveModel?) {
            didAdvance = true
        }
    }
}
