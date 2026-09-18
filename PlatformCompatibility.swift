#if os(macOS)
import SwiftUI

// Provide iOS-only toolbar placements on macOS as fallbacks
extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .automatic }
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
}

// No-op navigation bar title display mode on macOS
extension View {
    // Use Any to avoid referencing unavailable iOS types on macOS
    func navigationBarTitleDisplayMode(_ mode: Any) -> some View { self }
}

// Shims for text input configuration APIs that are iOS-only
enum TextInputAutocapitalization {
    case never, words, sentences, characters
}

extension View {
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization) -> some View { self }
    func autocorrectionDisabled(_ disabled: Bool = true) -> some View { self }
}
#endif
