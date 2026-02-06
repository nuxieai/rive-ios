//
//  SwiftTestText.swift
//  Example (iOS)
//
//  Created by Zach Plata on 7/27/23.
//  Copyright © 2023 Rive. All rights reserved.
//

import SwiftUI
import RiveRuntime

struct TextInputView: DismissableView {
    var dismiss: () -> Void = {}
    
    @StateObject private var rvm = RiveViewModel(fileName: "text_test_2")
    @State private var textInputHandle: RiveTextInputHandle?

    var body: some View {
        VStack(spacing: 20) {
            Text("Tap the text in the Rive view to edit:")
                .font(.headline)
            rvm.view()
                .onAppear {
                    Task { @MainActor in
                        guard textInputHandle == nil else { return }
                        do {
                            var binding = RiveTextInputBinding(textRunName: "MyRun")
                            binding.renderMode = .riveRendersText
                            textInputHandle = try rvm.bindTextInput(binding)
                        } catch {
                            debugPrint(error)
                        }
                    }
                }
                .onDisappear {
                    Task { @MainActor in
                        textInputHandle?.remove()
                        textInputHandle = nil
                    }
                }
        }
        .padding()
    }
}
