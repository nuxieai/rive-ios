# Rive iOS Text Input Overlay Spec

Status: Implemented (Prototype)

Owner: Rive iOS runtime

Last updated: 2026-02-06

## Current Implementation (2026-02-06)

- Public Swift API + overlay manager: `/Users/levi/dev/oss/rive-ios/Source/RiveView.swift`
- SwiftUI convenience: `/Users/levi/dev/oss/rive-ios/Source/RiveViewModel.swift`
- ObjC++ bridges:
  - `/Users/levi/dev/oss/rive-ios/Source/Renderer/include/rive_renderer_view.hh`
  - `/Users/levi/dev/oss/rive-ios/Source/Renderer/rive_renderer_view.mm`
  - `/Users/levi/dev/oss/rive-ios/Source/Renderer/include/RiveTextValueRun.h`
  - `/Users/levi/dev/oss/rive-ios/Source/Renderer/RiveTextValueRun.mm`
- Demo usage (Example app): `/Users/levi/dev/oss/rive-ios/Example-iOS/Source/Examples/SwiftUI/SwiftTestText.swift`

## Summary

Add first-class text input support to `rive-ios` by overlaying native `UITextField` / `UITextView` instances on top of a `RiveView`, while synchronizing edits into the Rive scene via `TextValueRun` updates.

The result should feel like a normal iOS text input (keyboard, selection handles, autocorrect, IME composition), but be positioned, sized, transformed, and styled from the Rive scene so it appears as part of the animation.

## Goals

- Native-feeling text editing:
  - Keyboard, selection, copy/paste, autocorrect, IME composition.
  - Works in UIKit and SwiftUI hosting.
- Rive receives text changes as the user types (near real-time).
- The text input view is positioned and transformed to match a Rive `Text` component:
  - Translation, scale, rotation, nested artboard transforms, and view `fit`/`alignment`.
  - Updated every frame while active/visible.
- Mirror most style attributes from Rive text styles by default:
  - Font face (embedded fonts), font size, line height, letter spacing, alignment, solid fill color (best effort), clipping/overflow.
  - Variable font weight mirroring supported via the `wght` axis when available.
- API is additive and opt-in; existing apps unchanged.

## Non-Goals (v1)

- Perfect caret/selection geometry for non-affine text effects:
  - Text-on-path, per-glyph warps/modifiers that cannot be represented by a single affine transform.
- Mirroring complex paints (gradients, strokes, blend modes) into UIKit text rendering.
- Rendering Rive cursor/selection visuals exactly (UIKit will render these).
- Providing a Rive-side "editable text" component authoring tool in the editor (this is an iOS runtime integration spec).

## Glossary

- Artboard space: the coordinate space of the root artboard being drawn by `RiveView`.
- View space: UIKit points in the `RiveView`'s coordinate space.
- `TextValueRun`: the runtime object that stores a run's string value (used today by `RiveTextValueRun` bridge).
- `Text` component: the drawable that owns text layout/bounds and style runs.
- Root transform: the nested-artboard "mount" transform chain that maps a nested artboard's coordinates into the root artboard space.

## Design Overview

1. Developer binds one or more text inputs to Rive `TextValueRun`s (by name + optional nested artboard `path`).
2. The runtime creates a native UIKit control:
   - `UITextField` for single-line.
   - `UITextView` for multi-line.
   - `.automatic` chooses based on Rive `Text` wrap + sizing (and existing line breaks).
3. Per frame (and on layout changes), the control is updated:
   - Compute an `artboardToView` matrix using the same `Fit`/`Alignment` math as rendering.
   - Get the Rive `Text` local bounds and a root-artboard-space world transform for the `Text`.
   - Set the control's `bounds`, `center`, and `transform` so it matches the text region in view space.
4. As the user edits:
   - On each edit change, call `setTextRunValue(...)` so Rive receives the new string.
   - Optionally toggle a state-machine input on focus/blur so the Rive scene can animate (e.g. hide Rive-rendered text during editing).

## Font Mirroring (iOS)

UIKit does not know about fonts embedded in a `.riv` file by default. To make
the overlay text inputs render with the exact same font face as Rive, the iOS
runtime registers font asset bytes with CoreText as they load.

Mechanism:

- During font asset load (both in-band and CDN), the runtime calls:
  - `RiveFontAssetRegistry.registerFont(assetKey:data:)`
- `assetKey` is `FileAsset::uniqueName()` so the mapping remains stable even if
  multiple assets share the same original name.
- `RiveFontAssetRegistry` extracts the PostScript name from the font bytes and
  registers the font using `CTFontManagerRegisterGraphicsFont`.
- When mirroring style for a `TextValueRun`, the overlay:
  - Reads `run.fontAssetKey()` and resolves it to a PostScript name.
  - Creates `UIFont(name:size:)` to match the embedded font face.

Variable weight (wght axis):

- Rive exposes the effective OpenType weight for the run (`run.fontWeight()`,
  in the range `[1, 1000]`).
- When the embedded font is variable, the overlay applies the `wght` axis via
  `kCTFontVariationAttribute` on the `UIFontDescriptor`, so UIKit glyph metrics
  match Rive's shaping when the weight is animated or set through variations.

## Public API (Swift)

### Types

```swift
public enum RiveTextInputKind {
    case automatic
    case singleLine
    case multiLine
}

public enum RiveTextInputRenderMode {
    /// Native view renders the glyphs. Recommended when style mirroring is acceptable.
    case nativeRendersText

    /// Native view is used for editing only; Rive continues rendering the text.
    /// Useful fallback when native style cannot match (complex paints/effects).
    case riveRendersText
}

public struct RiveTextInputBinding: Sendable {
    public var textRunName: String
    public var path: String?            // nested artboard path ("A/B/C")
    public var kind: RiveTextInputKind
    public var renderMode: RiveTextInputRenderMode

    /// Insets added to the hit rect in local text bounds (artboard units).
    public var hitSlop: UIEdgeInsets

    /// If true, tapping the bound text region focuses the field.
    public var focusOnTap: Bool

    /// Optional state-machine inputs to drive focus styling in the Rive file.
    /// When set, the runtime sets these on focus/blur.
    public var focusBoolInputName: String?
    public var focusBoolInputPath: String?
    public var focusTriggerInputName: String?
    public var focusTriggerInputPath: String?

    /// iOS text input traits (subset; extend as needed).
    public var keyboardType: UIKeyboardType
    public var returnKeyType: UIReturnKeyType
    public var textContentType: UITextContentType?
    public var autocapitalizationType: UITextAutocapitalizationType
    public var autocorrectionType: UITextAutocorrectionType
    public var spellCheckingType: UITextSpellCheckingType
    public var isSecureTextEntry: Bool

    /// Style mirroring defaults to true; developers can override via closures.
    public var mirrorStyleFromRive: Bool
    public var styleOverride: (@MainActor (UIView & UITextInputTraits) -> Void)?

    public init(textRunName: String, path: String? = nil) {
        self.textRunName = textRunName
        self.path = path
        self.kind = .automatic
        self.renderMode = .nativeRendersText
        self.hitSlop = .zero
        self.focusOnTap = true
        self.focusBoolInputName = nil
        self.focusBoolInputPath = nil
        self.focusTriggerInputName = nil
        self.focusTriggerInputPath = nil
        self.keyboardType = .default
        self.returnKeyType = .default
        self.textContentType = nil
        self.autocapitalizationType = .sentences
        self.autocorrectionType = .default
        self.spellCheckingType = .default
        self.isSecureTextEntry = false
        self.mirrorStyleFromRive = true
        self.styleOverride = nil
    }
}

public protocol RiveTextInputDelegate: AnyObject {
    func riveTextInputDidBeginEditing(_ input: RiveTextInputHandle)
    func riveTextInputDidChange(_ input: RiveTextInputHandle)
    func riveTextInputDidEndEditing(_ input: RiveTextInputHandle)
    func riveTextInputDidSubmit(_ input: RiveTextInputHandle)
}

public final class RiveTextInputHandle {
    public let binding: RiveTextInputBinding
    public var isEditing: Bool { /* ... */ }
    public func focus()
    public func blur()
    public func remove()
}
```

### RiveView / RiveViewModel entry points

```swift
extension RiveView {
    /// Creates and manages an overlay text input bound to a TextValueRun.
    @MainActor
    public func bindTextInput(_ binding: RiveTextInputBinding) throws -> RiveTextInputHandle

    @MainActor
    public func unbindTextInput(_ handle: RiveTextInputHandle)

    @MainActor
    public func unbindAllTextInputs()

    public weak var textInputDelegate: RiveTextInputDelegate?
}

extension RiveViewModel {
    /// Convenience: forwards to the currently registered RiveView (if any).
    @MainActor
    public func bindTextInput(_ binding: RiveTextInputBinding) throws -> RiveTextInputHandle
}
```

Notes:
- Bindings are view-level because they create UIKit subviews and rely on view `fit`/`alignment`.
- `RiveViewModel` provides convenience for SwiftUI users.
- Objective-C surface area can be added later (or mirrored with `@objc` wrappers).

## Layout + Transform Spec

### Required runtime info per bound input

For a bound `TextValueRun`, we need:
- `textLocalBounds`: the `Text` component local bounds in text-local coordinates (artboard units).
- `textRootWorldTransform`: the `Text` component world transform expressed in *root artboard space* (to handle nested artboards).

Implementation detail:
- `TextValueRun::textComponent()` gives the owning `Text*`.
- `Text::localBounds()` provides local bounds (already origin-adjusted).
- `Text::worldTransform()` gives world transform inside its containing artboard.
- If the text lives in a nested artboard instance, convert to root space using `Artboard::rootTransform(...)`:
  - Reconstruct an affine matrix by mapping (0,0), (1,0), (0,1) from text-local through `Text::worldTransform()` into the containing artboard, then through `artboard->rootTransform(...)` into the root artboard.

### Artboard -> View transform

Compute the same alignment matrix used by rendering:

- `frame` = `[0, 0, riveView.bounds.width, riveView.bounds.height]` (points)
- `content` = `artboard.bounds()` (root artboard bounds, artboard units)
- `fit` / `alignment` = current `RiveView.fit` / `RiveView.alignment`
- `scaleFactor` for `Fit.layout`:
  - `scaleFactor = frame.width / content.width` (matches existing touch mapping logic)

Then:
- `artboardToView = rive::computeAlignment(fit, alignment, frame, content, scaleFactor)`

### Final mapping

`textLocal -> view` mapping:

```
M = artboardToView * textRootWorldTransform
```

Apply to native view using UIKit-friendly decomposition:
- `bounds.size = textLocalBounds.size` (in artboard units)
- `center = M * textLocalBounds.center` (in view points)
- `transform = linear(M)` (a,b,c,d; no translation)

This yields the correct mapping for any point inside the local bounds under an affine transform.

### Update cadence

Update transform when any of the following changes:
- Each draw cycle while the input is visible or editing (recommended).
- Any `RiveView` layout change (`layoutSubviews`, `drawableSizeDidChange`, `fit`, `alignment`, `layoutScaleFactor` changes).
- Any artboard advance while visible/editing.

Optimization (optional):
- Cache last applied `M` and local bounds; skip updates if unchanged within epsilon.

## Choosing UITextField vs UITextView

If `kind == .automatic`:
- Use `UITextField` when the bound `Text` has `wrap == noWrap`.
- Use `UITextField` when the bound `Text` has `sizing == autoWidth` (unbounded width) and the current text has no line breaks.
- Use `UITextView` when wrap allows multiple lines and sizing is constrained.

Developer can force the choice with `.singleLine` / `.multiLine`.

## Style Mirroring (Default On)

Mirroring is "best effort". If a property cannot be mirrored reliably, leave the UIKit default or allow the developer to override.

### Typography

Mirror from the bound run's `TextStylePaint` and its owning `Text`:
- `fontSize` -> `UIFont` size (in artboard units; UIKit view transform handles scaling).
- `lineHeight` -> `NSParagraphStyle` min/max line height (when supported).
  - If Rive `lineHeight == -1`, use font default metrics.
- `letterSpacing` -> `NSAttributedString.Key.kern`.
- Horizontal alignment (`TextAlign`) -> `NSTextAlignment`.
- Wrap/overflow:
  - `wrap == noWrap` -> single-line behavior.
  - Non-visible overflow -> set `clipsToBounds = true`.

Implementation note:
- For editable text, `UITextView` styling is most reliable via `typingAttributes` and applying attributes to `attributedText` carefully without disrupting `markedTextRange`.

### Color

Mirror solid fill color when available:
- Inspect the `TextStylePaint` shape paints.
- Choose the first visible `Fill` paint whose mutator is a `SolidColor`.
- Convert `SolidColor.colorValue()` (ARGB) to `UIColor`.
- Apply:
  - `textColor` (native-render mode).
  - `tintColor` (caret/selection accent) as a reasonable default.

Fallback:
- If no solid fill is found, use `.label` for `textColor` and `.systemBlue` for `tintColor`, unless overridden.

### Fonts (Custom Fonts)

Goal: use a `UIFont` that matches the Rive font asset when possible.

Proposed mechanism:
- Maintain an internal cache keyed by Rive font asset `uniqueName` (and optionally variation axes).
- Populate cache when font assets are encountered during file import:
  - For in-band font bytes: a small `FileAssetLoader` can observe `FontAsset` in-band bytes, cache the `NSData`, then return `false` to allow default decoding.
  - For CDN-loaded fonts: update `CDNFileAssetLoader` to also populate the cache when the download completes.
- Create `CTFont` / `UIFont` from cached bytes using CoreText.

Fallback:
- If the cache is missing or font creation fails, fall back to `UIFont.systemFont(ofSize:)`.

Developer override:
- `RiveTextInputBinding.styleOverride` can set a custom font.

## Text Synchronization Rules

### Source of truth

- While editing: native control is the source of truth.
- When not editing: Rive `TextValueRun` is the source of truth (and the native control may be hidden).

### Writing to Rive

On user changes:
- For each `editingChanged` (UITextField) or `textViewDidChange` (UITextView), call:
  - `RiveViewModel.setTextRunValue(textRunName, path: ..., textValue: currentText)`
- If the view is not playing, force a zero-delta advance to update transforms/animations:
  - This is consistent with existing `setTextRunValue` behavior in `RiveViewModel`.

IME composition:
- Do not programmatically set the native control's text while `markedTextRange != nil`.
- Rive can receive the full composed string (what the user sees) on each change, but avoid feedback loops:
  - If the change originated from the native control, do not re-apply the same string back into the control.

### Reading from Rive

When binding or when editing begins:
- Initialize native control text from current `TextValueRun.text`.

If the app changes the run text while editing (rare but possible):
- Default policy: ignore external Rive-side updates while editing.
- Optional future policy: if the update is different and there is no marked text, merge/replace.

## Focus + Hit Testing

Default behavior:
- If `focusOnTap == true`, the runtime hit-tests taps on the `RiveView` against each bound input's text region.

Hit test procedure:
1. Convert touch point in view space -> artboard space using existing `artboardLocation(...)`.
2. For each binding:
   - Get `textRootWorldTransform` and invert it.
   - Convert artboard point -> text-local point.
   - Check containment in `textLocalBounds.insetBy(hitSlop)`.
3. Focus the first match (or highest z-order if later extended).

Focus styling in Rive (recommended):
- If `focusBoolInputName` is set, set that bool input to `true` on begin editing and `false` on end.
- If `focusTriggerInputName` is set, fire on begin editing.

Rive file recommendation:
- Have a state machine that:
  - Hides the Rive-rendered text while editing (to avoid double text).
  - Plays focus/blur animations (cursor, outline, etc).

## Rendering Modes

### nativeRendersText (default)

- Native control is visible and styled to match Rive.
- Rive file should hide/ghost the original text while editing (preferred) or accept double rendering.

### riveRendersText

- Native control is present, focuses, and receives keyboard input, but its text rendering is visually hidden:
  - `textColor = .clear`
  - still set `tintColor` to show caret/selection handles
- Rive continues rendering text (always matches effects/paints).
- Caveat: selection highlight geometry comes from UIKit layout and may not match Rive exactly.

## Lifecycle + Integration Points

### Where to run layout updates

Preferred:
- Update overlay transforms during `RiveView.drawRive(_:size:)` after the artboard size is configured (important for `Fit.layout`).

Also update on:
- `layoutSubviews`
- `drawableSizeDidChange`
- `setModel(...)` / model replacement
- `deinit` (cleanup)

### Offscreen behavior

If `RiveView.offscreenBehavior == .playAndNoDraw` and the view is offscreen:
- Hide overlay inputs and blur if editing (to avoid an invisible-but-interactive control).
- Restore if it becomes visible again (app-defined; may require re-focus).

## Error Handling

Binding should throw a `RiveError` when:
- The artboard is missing.
- The requested `TextValueRun` cannot be found (name/path).
- Text support is not compiled (`WITH_RIVE_TEXT` off).

## Objective-C / Bridge Requirements

Extend `RiveTextValueRun` bridge (ObjC++) to expose the info needed for layout + mirroring, behind `WITH_RIVE_TEXT`:

- `-(CGRect)textLocalBounds;`
- `-(CGAffineTransform)textRootWorldTransform;`  // root artboard space
- `-(NSInteger)textWrap;` / `textAlign` / `textOverflow` / `textVerticalAlign` (enum mirrors)
- `-(CGFloat)styleFontSize;`
- `-(CGFloat)styleLineHeight;`
- `-(CGFloat)styleLetterSpacing;`
- `-(UIColor* _Nullable)styleSolidFillColor;`    // best-effort
- `-(NSString* _Nullable)styleFontAssetUniqueName;` // for font cache lookup

Add a forward-transform helper on `RiveRendererView` (or Swift-side equivalent) to compute `artboardToView` matrix:

- `- (CGAffineTransform)artboardToViewTransformForArtboardRect:(CGRect)artboardRect fit:(RiveFit)fit alignment:(RiveAlignment)alignment;`

These APIs are internal implementation details; public Swift API can remain Swift-only if desired.

## Testing Plan

Automated:
- Unit test matrix reconstruction for nested artboards:
  - Verify mapping of 3 basis points matches expected root transforms.
- Unit test that overlay view transform matches computeAlignment for a set of fits/alignments.
- Regression tests for IME marked text handling (as feasible).

Manual matrix (must pass):
- iPhone + iPad, portrait/landscape.
- Fit modes: contain, cover, fill, layout.
- Rotated/scaled text nodes.
- Nested artboard text (path set).
- Secure entry, content types, return key handling.
- Multi-line with scrolling enabled/disabled.

## Known Limitations / Caveats

- UIKit text editing UI under rotation/scaling is generally supported but can be visually odd at extreme transforms.
- Non-affine text effects in Rive cannot be mirrored perfectly by a single UIKit view.
- Complex paint styles (gradients, strokes, blend modes) will not mirror; use `riveRendersText` mode or accept approximation.

## Future Work

- Caret/selection geometry driven by Rive's text shaping (glyph bounds), for better visual match.
- Better z-order integration: choose topmost text input based on draw order.
- Expose a higher-level authoring contract (naming conventions or metadata/custom properties) to declare editable fields in `.riv`.
