//
//  RiveView.swift
//  RiveRuntime
//
//  Created by Zachary Duncan on 3/23/22.
//  Copyright © 2022 Rive. All rights reserved.
//

import Foundation
#if canImport(UIKit)
import UIKit
import CoreText
#endif

open class RiveView: RiveRendererView {
    struct Constants {
        static let layoutScaleFactorAutomatic: Double = -1
    }

    public enum OffscreenBehavior {
        case playAndDraw
        case playAndNoDraw
    }

    public enum DrawOptimization {
        case alwaysDraw
        case drawOnChanged
    }

    // MARK: Configuration
    internal weak var riveModel: RiveModel?
    internal var fit: RiveFit = .contain { didSet { needsDisplay() } }
    internal var alignment: RiveAlignment = .center { didSet { needsDisplay() } }
    /// The scale factor to apply when using the `layout` fit. By default, this value is -1, where Rive will determine
    /// the correct scale for your device.To override this default behavior, set this value to a value greater than 0. This value should
    /// only be set at the view model level and passed into this view.
    /// - Note: If the scale factor <= 0, nothing will be drawn.
    internal var layoutScaleFactor: Double = RiveView.Constants.layoutScaleFactorAutomatic { didSet { needsDisplay() } }
    /// The internally calculated layout scale to use if a scale is not set by the developer (i.e layoutScaleFactor == -1)
    /// Defaults to the "legacy" methods, which will be overridden
    /// by window handlers in this view when the window changes.
    private lazy var _layoutScaleFactor: Double = {
        #if os(iOS) || os(visionOS) || os(tvOS)
        return self.traitCollection.displayScale
        #else
        guard let scale = NSScreen.main?.backingScaleFactor else { return 1 }
        return scale
        #endif
    }() {
        didSet { needsDisplay() }
    }
    /// Sets whether or not the Rive view should forward Rive listener touch / click events to any next responders.
    /// When true, touch / click events will be forwarded to any next responder(s).
    /// When false, only the Rive view will handle touch / click events, and will not forward
    /// to any next responder(s). Defaults to `false`, as to preserve pre-existing runtime functionality.
    /// - Note: On iOS, this is handled separately from `isExclusiveTouch`.
    internal var forwardsListenerEvents: Bool = false

    /// Sets whether the view should continue drawing while offscreen.
    public var offscreenBehavior: OffscreenBehavior = .playAndNoDraw

    /// Sets whether the view should always draw, or skip drawing
    /// if the artboard is unchanged.
    public var drawOptimization: DrawOptimization = .drawOnChanged
    private var forceDraw: Bool = false

    // MARK: Render Loop
    internal private(set) var isPlaying: Bool = false
    private var lastTime: CFTimeInterval = 0
    private var displaySync: RiveDisplayLink?
    private var eventQueue = EventQueue()

    // MARK: FPS
    private var userFPS: Any?
    private var userPreferredFramesPerSecond: Int? {
        return userFPS as? Int
    }
    @available(iOS 15, tvOS 15, visionOS 1, *)
    private var userPreferredFrameRateRange: CAFrameRateRange? {
        return userFPS as? CAFrameRateRange
    }

    // MARK: Delegates
    @objc public weak var playerDelegate: RivePlayerDelegate?
    public weak var stateMachineDelegate: RiveStateMachineDelegate?
#if canImport(UIKit)
    public weak var textInputDelegate: RiveTextInputDelegate?
    private var textInputOverlaysByID: [UUID: _RiveTextInputOverlay] = [:]
#endif
    
    // MARK: Debug
    private var fpsCounter: FPSCounterView? = nil
    /// Shows or hides the FPS counter on this RiveView
    public var showFPS: Bool = RiveView.showFPSCounters { didSet { setFPSCounterVisibility() } }
    /// Shows or hides the FPS counters on all RiveViews
    public static var showFPSCounters = false

    open override var bounds: CGRect {
        didSet {
            redrawIfNecessary()
        }
    }

    open override var frame: CGRect {
        didSet {
            if oldValue != frame {
                forceDraw = true
            }
            redrawIfNecessary()
        }
    }

    private var orientationObserver: (any NSObjectProtocol)?
    private var screenObserver: (any NSObjectProtocol)?

    #if !os(macOS)
    private var touchPool = IDPool<UITouch>(range: 0..<10)
    #endif

    /// Minimalist constructor, call `.configure` to customize the `RiveView` later.
    public init() {
        super.init(frame: .zero)
        commonInit()
    }
    
    public convenience init(model: RiveModel, autoPlay: Bool = true) {
        self.init()
        commonInit()
        try! setModel(model, autoPlay: autoPlay)
    }

    
    #if os(visionOS)
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    #else
    required public init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    #endif

    private func commonInit() {
        #if os(iOS) || os(visionOS) || os(tvOS)
        if #available(iOS 17, tvOS 17, visionOS 1, *) {
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { [weak self] (_: UITraitEnvironment, traitCollection: UITraitCollection) in
                guard let self else { return }
                self.redrawIfNecessary()
            }
        }

        if #available(iOS 17, tvOS 17, visionOS 1, *) {
            registerForTraitChanges([UITraitDisplayScale.self]) { [weak self] (_: UITraitEnvironment, previousTraitCollection: UITraitCollection) in
                guard let self else { return }
                if previousTraitCollection.displayScale != traitCollection.displayScale {
                    updateLayoutScaleFactor()
                }
            }
        }
        #endif

        #if os(iOS)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.redrawIfNecessary()
        }
        #endif

        #if os(macOS)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: nil) { [weak self] _ in
                self?.updateLayoutScaleFactor()
            }
        #endif
    }

    deinit {
#if canImport(UIKit)
        _removeAllTextInputOverlays()
#endif
        stopTimer()
        
        #if os(iOS)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer as Any)
        }
        #endif

        #if os(macOS)
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer as Any)
        }
        #endif
        
        orientationObserver = nil
        screenObserver = nil
    }

    private func needsDisplay() {
        #if os(iOS) || os(visionOS) || os(tvOS)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    #if os(macOS)
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayoutScaleFactor()
    }
    #else
    open override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLayoutScaleFactor()
    }
    #endif

    /// This resets the view with the new model. Useful when the `RiveView` was initialized without one.
    @objc open func setModel(_ model: RiveModel, autoPlay: Bool = true) throws {
        stopTimer()
        isPlaying = false
        riveModel = model
        #if os(iOS) || os(visionOS) || os(tvOS)
            isOpaque = false
        #else
            layer?.isOpaque=false
        #endif
        
        
        if autoPlay {
            play()
        } else {
            advance(delta: 0)
        }
        
        setFPSCounterVisibility()
    }

    /// Hints to underlying CADisplayLink the preferred FPS to run at
    /// - Parameters:
    ///   - preferredFramesPerSecond: Integer number of seconds to set preferred FPS at
    @objc(setPreferredFPS:)
    open func setPreferredFramesPerSecond(preferredFramesPerSecond: Int) {
        userFPS = preferredFramesPerSecond
        displaySync?.set(preferredFramesPerSecond: preferredFramesPerSecond)
    }
    
    /// Hints to underlying CADisplayLink the preferred frame rate range
    /// - Parameters:
    ///   - preferredFrameRateRange: Frame rate range to set
    @available(iOS 15, macOS 14, tvOS 15, visionOS 1, *)
#if !os(macOS) // The automatic Swift bridging header doesn't like bridging CAFrameRateRange automatically
    @objc(setPreferredFrameRateRange:)
#endif
    open func setPreferredFrameRateRange(preferredFrameRateRange: CAFrameRateRange) {
        userFPS = preferredFrameRateRange
        displaySync?.set(preferredFrameRateRange: preferredFrameRateRange)
    }
    
    // MARK: - Controls
    
    /// Starts the render loop
    internal func play() {
        RiveLogger.log(view: self, event: .play)

        eventQueue.add {
            self.playerDelegate?.player(playedWithModel: self.riveModel)
        }
        
        isPlaying = true
        startTimer()
    }
    
    /// Asks the render loop to stop on the next cycle
    internal func pause() {
        RiveLogger.log(view: self, event: .pause)

        if isPlaying {
            eventQueue.add {
                self.playerDelegate?.player(pausedWithModel: self.riveModel)
            }
            isPlaying = false
        }
    }
    
    /// Asks the render loop to stop on the next cycle
    internal func stop() {
        RiveLogger.log(view: self, event: .stop)

        playerDelegate?.player(stoppedWithModel: riveModel)
        isPlaying = false
        
        reset()
    }
    
    internal func reset() {
        RiveLogger.log(view: self, event: .reset)

        lastTime = 0

        if !isPlaying {
            advance(delta: 0)
        }
    }
    
    // MARK: - Render Loop
    
    private func startTimer() {
        #if os(macOS)
        if #available(macOS 14, *) {
            guard displaySync == nil else { return }
            displaySync = RiveCADisplayLink(view: self) { [weak self] in
                self?.tick()
            }
        } else {
            guard displaySync == nil else { return }
            displaySync = RiveCVDisplaySync { [weak self] in
                self?.tick()
            }
        }
        #else
        guard displaySync == nil else { return }
        displaySync = RiveCADisplayLink(windowScene: window?.windowScene) { [weak self] in
            self?.tick()
        }
        if let fps = userPreferredFramesPerSecond {
            setPreferredFramesPerSecond(preferredFramesPerSecond: fps)
        } else if #available(iOS 15, tvOS 15, visionOS 1, *), let range = userPreferredFrameRateRange {
            setPreferredFrameRateRange(preferredFrameRateRange: range)
        }
        #endif
        displaySync?.start()
    }
    
    private func stopTimer() {
        displaySync?.stop()
        displaySync = nil
        lastTime = 0
        fpsCounter?.stopped()
    }
    
    private func timestamp() -> CFTimeInterval {
        return displaySync?.targetTimestamp ?? Date().timeIntervalSince1970
    }

    /// Start a redraw:
    /// - determine the elapsed time
    /// - advance the artbaord, which will invalidate the display.
    /// - if the artboard has come to a stop, stop.
    @objc fileprivate func tick() {
        guard displaySync != nil else {
            stopTimer()
            return
        }
        
        let timestamp = timestamp()
        // last time needs to be set on the first tick
        if lastTime == 0 {
            lastTime = timestamp
        }
        
        // Calculate the time elapsed between ticks
        let elapsedTime = timestamp - lastTime
        
        #if os(iOS) || os(visionOS) || os(tvOS)
            fpsCounter?.didDrawFrame(timestamp: timestamp)
        #else
            fpsCounter?.elapsed(time: elapsedTime)
        #endif
            
        
        lastTime = timestamp
        advance(delta: elapsedTime)
        if !isPlaying {
            stopTimer()
        }
    }
    
    /// Advances the Artboard and either a StateMachine or an Animation.
    /// Also fires any remaining events in the queue.
    ///
    /// - Parameter delta: elapsed seconds since the last advance
    @objc open func advance(delta: Double) {
        let wasPlaying = isPlaying
        eventQueue.fireAll()
        
        if let stateMachine = riveModel?.stateMachine {
            let firedEventCount = stateMachine.reportedEventCount()
            if (firedEventCount > 0) {
                for i in 0..<firedEventCount {
                    let event = stateMachine.reportedEvent(at: i)
                    RiveLogger.log(view: self, event: .eventReceived(event.name()))
                    stateMachineDelegate?.onRiveEventReceived?(onRiveEvent: event)
                }
            }
            var shouldAdvance = stateMachine.advance(by: delta)
            if delta == 0 {
                shouldAdvance = true
            }
            isPlaying = shouldAdvance && wasPlaying

            if let delegate = stateMachineDelegate {
                stateMachine.stateChanges().forEach { delegate.stateMachine?(stateMachine, didChangeState: $0) }
            }

            stateMachine.viewModelInstance?.updateListeners()
        } else if let animation = riveModel?.animation {
            isPlaying = animation.advance(by: delta) && wasPlaying

            if isPlaying {
                if animation.didLoop() {
                    playerDelegate?.player(loopedWithModel: riveModel, type: Int(animation.loop()))
                }
            }
        }
        
        if !isPlaying {
            stopTimer()
            
            // This will be true when coming to a hault automatically
            if wasPlaying {
                RiveLogger.log(view: self, event: .pause)
                playerDelegate?.player(pausedWithModel: riveModel)
            }
        }
        
        RiveLogger.log(view: self, event: .advance(delta))
        playerDelegate?.player(didAdvanceby: delta, riveModel: riveModel)
        
        // Trigger a redraw
        needsDisplay()
    }
    /// This is called in the middle of drawRect. Override this method to implement
    /// custom draw logic
    override open func drawRive(_ rect: CGRect, size: CGSize) {
        // This prevents breaking when loading RiveFile async
        guard let artboard = riveModel?.artboard else { return }

        let scale = layoutScaleFactor == RiveView.Constants.layoutScaleFactorAutomatic ? _layoutScaleFactor : layoutScaleFactor

        RiveLogger.log(view: self, event: .drawing(size))
        let newFrame = CGRect(origin: rect.origin, size: size)
        if (fit == RiveFit.layout) {
            if scale <= 0 {
                RiveLogger.log(view: self, event: .error("Cannot draw with a scale factor of \(scale)"))
                return
            }
            artboard.setWidth(Double(newFrame.width) / scale);
            artboard.setHeight(Double(newFrame.height) / scale);
        } else {
            artboard.resetArtboardSize();
        }
        align(with: newFrame, contentRect: artboard.bounds(), alignment: alignment, fit: fit, scaleFactor: scale)
        draw(with: artboard)

#if canImport(UIKit)
        updateTextInputOverlays()
#endif
    }

    open override func draw(_ rect: CGRect) {
        // First check whether we should draw and we're on-screen
        if offscreenBehavior == .playAndDraw || isOnscreen() {
            // Then check our optimization. Draw if:
            // 1. We always draw, or
            // 2. If we don't, if the artboard changed
            // 3. foceDraw == true; e.g our frame has changed, but we want to maintain the rendering transform
            guard let artboard = riveModel?.artboard,
            (drawOptimization == .alwaysDraw || artboard.didChange || forceDraw)
            else { return }

            super.draw(rect)
            forceDraw = false
        }
    }

    open override func drawableSizeDidChange(_ drawableSize: CGSize) {
        super.drawableSizeDidChange(drawableSize)
        if fit == .layout, let artboard = riveModel?.artboard {
            let currentSize = drawableSize
            let artboardSize = artboard.bounds().size
            if currentSize != artboardSize {
                // We can use currentSize; we are mirroring setting
                // the updated layout size (if needed) as in drawRive,
                // which uses the same rect as drawRect (assuming 'self')
                let scale = layoutScaleFactor == RiveView.Constants.layoutScaleFactorAutomatic ? _layoutScaleFactor : layoutScaleFactor
                artboard.setWidth(Double(currentSize.width) / scale)
                artboard.setHeight(Double(currentSize.height) / scale)
                advance(delta: 0)
            }
        }
    }

#if canImport(UIKit) || RIVE_MAC_CATALYST
    open override func layoutSubviews() {
        super.layoutSubviews()
        drawableSizeDidChange(drawableSize)
#if canImport(UIKit)
        updateTextInputOverlays()
#endif
    }
    #endif

    #if os(iOS)
    open override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
#if canImport(UIKit)
        updateTextInputOverlays()
#endif
    }
    #endif

    #if canImport(AppKit) && !RIVE_MAC_CATALYST
    open override func layout() {
        super.layout()
        drawableSizeDidChange(drawableSize)
    }
    #endif

    // MARK: - UITraitCollection
    #if os(iOS)
    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if #unavailable(iOS 17) {
            if traitCollection.horizontalSizeClass != previousTraitCollection?.horizontalSizeClass
                || traitCollection.verticalSizeClass != previousTraitCollection?.verticalSizeClass {
                redrawIfNecessary()
            }

            if traitCollection.displayScale != previousTraitCollection?.displayScale {
                updateLayoutScaleFactor()
            }
        }
    }
    #endif

    // MARK: - UIResponder
    #if os(iOS) || os(visionOS) || os(tvOS)
        open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
#if canImport(UIKit)
                let location = touch.location(in: self)
                if focusTextInputIfNeeded(at: location) {
                    continue
                }
#endif
                guard let id = touchPool.add(touch) else {
                    return
                }
                handleTouch(touch, delegate: stateMachineDelegate?.touchBegan) { stateMachine, location in
                    let result = stateMachine.touchBegan(atLocation: location, touchID: id)
                    RiveLogger.log(view: self, event: .touchBegan(location, id))

                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .began)
                    }
                }
            }

            if forwardsListenerEvents == true {
                super.touchesBegan(touches, with: event)
            }
        }
        
        open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                guard let id = touchPool.add(touch) else {
                    return
                }
                handleTouch(touch, delegate: stateMachineDelegate?.touchMoved) { stateMachine, location in
                    RiveLogger.log(view: self, event: .touchMoved(location, id))

                    let result = stateMachine.touchMoved(atLocation: location, touchID: id)
                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .moved)
                    }
                }
            }

            if forwardsListenerEvents == true {
                super.touchesMoved(touches, with: event)
            }
        }
        
        open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                guard let id = touchPool.id(for: touch) else {
                    return
                }
                touchPool.remove(touch)

                handleTouch(touch, delegate: stateMachineDelegate?.touchEnded) { stateMachine, location in
                    RiveLogger.log(view: self, event: .touchEnded(location, id))

                    var result = stateMachine.touchEnded(atLocation: location, touchID: id)
                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .ended)
                    }

                    RiveLogger.log(view: self, event: .touchExited(location, id))
                    result = stateMachine.touchExited(atLocation: location, touchID: id)
                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .exited)
                    }
                }
            }

            if forwardsListenerEvents == true {
                super.touchesEnded(touches, with: event)
            }
        }
        
        open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                guard let id = touchPool.id(for: touch) else {
                    return
                }
                touchPool.remove(touch)

                handleTouch(touch, delegate: stateMachineDelegate?.touchCancelled) { stateMachine, location in
                    RiveLogger.log(view: self, event: .touchCancelled(location, id))

                    var result = stateMachine.touchCancelled(atLocation: location, touchID: id)
                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .cancelled)
                    }

                    RiveLogger.log(view: self, event: .touchExited(location, id))
                    result = stateMachine.touchExited(atLocation: location, touchID: id)
                    if let stateMachine = riveModel?.stateMachine {
                        stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .exited)
                    }
                }
            }

            if forwardsListenerEvents == true {
                super.touchesCancelled(touches, with: event)
            }
        }
        
        /// Sends incoming touch event to all playing `RiveStateMachineInstance`'s
        /// - Parameters:
        ///   - touch: The `CGPoint` where the touch occurred in `RiveView` coordinate space
        ///   - delegateAction: The delegate callback that should be triggered by this touch event
        ///   - stateMachineAction: Param1: A playing `RiveStateMachineInstance`, Param2: `CGPoint`
        ///   location where touch occurred in `artboard` coordinate space
        private func handleTouch(
            _ touch: UITouch,
            delegate delegateAction: ((RiveArtboard?, CGPoint)->Void)?,
            stateMachineAction: (RiveStateMachineInstance, CGPoint)->Void
        ) {
            guard let artboard = riveModel?.artboard else { return }
            guard let stateMachine = riveModel?.stateMachine else { return }
            let location = touch.location(in: self)
            
            let artboardLocation = artboardLocation(
                fromTouchLocation: location,
                inArtboard: artboard.bounds(),
                fit: fit,
                alignment: alignment
            )
            
            stateMachineAction(stateMachine, artboardLocation)
            play()
            
            // We send back the touch location in UIView coordinates because
            // users cannot query or manually control the coordinates of elements
            // in the Artboard. So that information would be of no use.
            delegateAction?(artboard, location)
        }
    #else
        open override func mouseDown(with event: NSEvent) {
            handleTouch(event, delegate: stateMachineDelegate?.touchBegan) { stateMachine, location in
                RiveLogger.log(view: self, event: .touchBegan(location, 0))

                let result = stateMachine.touchBegan(atLocation: location)
                if let stateMachine = riveModel?.stateMachine {
                    stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .began)
                }
            }

            if forwardsListenerEvents == true {
                super.mouseDown(with: event)
            }
        }
        
        open override func mouseMoved(with event: NSEvent) {
            handleTouch(event, delegate: stateMachineDelegate?.touchMoved) { stateMachine, location in
                RiveLogger.log(view: self, event: .touchMoved(location, 0))

                let result = stateMachine.touchMoved(atLocation: location)
                if let stateMachine = riveModel?.stateMachine {
                    stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .moved)
                }
            }

            if forwardsListenerEvents == true {
                super.mouseMoved(with: event)
            }
        }
        
        open override func mouseDragged(with event: NSEvent) {
            handleTouch(event, delegate: stateMachineDelegate?.touchMoved) { stateMachine, location in
                RiveLogger.log(view: self, event: .touchMoved(location, 0))

                let result = stateMachine.touchMoved(atLocation: location)
                if let stateMachine = riveModel?.stateMachine {
                    stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .moved)
                }
            }

            if forwardsListenerEvents == true {
                super.mouseDragged(with: event)
            }
        }
        
        open override func mouseUp(with event: NSEvent) {
            handleTouch(event, delegate: stateMachineDelegate?.touchEnded) { stateMachine, location in
                RiveLogger.log(view: self, event: .touchEnded(location, 0))

                let result = stateMachine.touchEnded(atLocation: location)
                if let stateMachine = riveModel?.stateMachine {
                    stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .ended)
                }
            }

            if forwardsListenerEvents == true {
                super.mouseUp(with: event)
            }
        }
        
        open override func mouseExited(with event: NSEvent) {
            handleTouch(event, delegate: stateMachineDelegate?.touchCancelled) { stateMachine, location in
                RiveLogger.log(view: self, event: .touchCancelled(location, 0))

                let result = stateMachine.touchCancelled(atLocation: location)
                if let stateMachine = riveModel?.stateMachine {
                    stateMachineDelegate?.stateMachine?(stateMachine, didReceiveHitResult: result, from: .cancelled)
                }
            }

            if forwardsListenerEvents == true {
                super.mouseExited(with: event)
            }
        }
        
        open override func updateTrackingAreas() {
            addTrackingArea(
                NSTrackingArea(
                    rect: self.bounds,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                    owner: self,
                    userInfo: nil
                )
            )
        }
        
        /// Sends incoming touch event to all playing `RiveStateMachineInstance`'s
        /// - Parameters:
        ///   - touch: The `CGPoint` where the touch occurred in `RiveView` coordinate space
        ///   - delegateAction: The delegate callback that should be triggered by this touch event
        ///   - stateMachineAction: Param1: A playing `RiveStateMachineInstance`, Param2: `CGPoint`
        ///   location where touch occurred in `artboard` coordinate space
        private func handleTouch(
            _ event: NSEvent,
            delegate delegateAction: ((RiveArtboard?, CGPoint)->Void)?,
            stateMachineAction: (RiveStateMachineInstance, CGPoint)->Void
        ) {
            guard let artboard = riveModel?.artboard else { return }
            guard let stateMachine = riveModel?.stateMachine else { return }
            let location = convert(event.locationInWindow, from: nil)
            
            // This is conforms the point to UIView coordinates which the
            // RiveRendererView expects in its artboardLocation method
            let locationFlippedY = CGPoint(x: location.x, y: frame.height - location.y)
            
            let artboardLocation = artboardLocation(
                fromTouchLocation: locationFlippedY,
                inArtboard: artboard.bounds(),
                fit: fit,
                alignment: alignment
            )
            
            stateMachineAction(stateMachine, artboardLocation)
            play()
            
            // We send back the touch location in NSView coordinates because
            // users cannot query or manually control the coordinates of elements
            // in the Artboard. So that information would be of no use.
            delegateAction?(artboard, location)
        }
    #endif
    
    // MARK: - Text Input Overlay (UIKit)
    #if canImport(UIKit)

    /// Creates and manages an overlay text input bound to a `TextValueRun`.
    @MainActor
    @discardableResult
    public func bindTextInput(_ binding: RiveTextInputBinding) throws -> RiveTextInputHandle {
        let handle = RiveTextInputHandle(binding: binding)
        try attachTextInput(handle)
        return handle
    }

    @MainActor
    public func unbindTextInput(_ handle: RiveTextInputHandle) {
        removeTextInput(handle.id)
        handle.detach()
    }

    @MainActor
    public func unbindAllTextInputs() {
        let handles = textInputOverlaysByID.keys.compactMap { id in
            textInputOverlaysByID[id]?.handle
        }
        _removeAllTextInputOverlays()
        handles.forEach { $0.detach() }
    }

    @MainActor
    func attachTextInput(_ handle: RiveTextInputHandle) throws {
        guard handle.riveView == nil || handle.riveView === self else {
            throw RiveTextInputError.bindingAlreadyAttachedToAnotherView
        }

        #if WITH_RIVE_TEXT
        guard let artboard = riveModel?.artboard else {
            throw RiveTextInputError.missingArtboard
        }

        let run: RiveTextValueRun?
        if let path = handle.binding.path, !path.isEmpty {
            run = artboard.textRun(handle.binding.textRunName, path: path)
        } else {
            run = artboard.textRun(handle.binding.textRunName)
        }

        guard let run else {
            throw RiveTextInputError.textRunNotFound(
                name: handle.binding.textRunName,
                path: handle.binding.path
            )
        }

        // Idempotent for the same handle id.
        if let existing = textInputOverlaysByID[handle.id] {
            handle.attach(to: self, textInputView: existing.view)
            return
        }

        let overlay = _RiveTextInputOverlay(handle: handle, initialRun: run, riveView: self)
        textInputOverlaysByID[handle.id] = overlay

        addSubview(overlay.view)
        updateTextInputOverlays()

        #else
        throw RiveTextInputError.textNotSupportedByBuild
        #endif
    }

    @MainActor
    fileprivate func removeTextInput(_ id: UUID) {
        guard let overlay = textInputOverlaysByID.removeValue(forKey: id) else { return }
        overlay.blur()
        overlay.view.removeFromSuperview()
    }

    fileprivate func _removeAllTextInputOverlays() {
        // This can be invoked from `deinit`, so keep it synchronous and best-effort.
        for (_, overlay) in textInputOverlaysByID {
            overlay.blur()
            overlay.view.removeFromSuperview()
        }
        textInputOverlaysByID.removeAll()
    }

    fileprivate func updateTextInputOverlays() {
        guard !textInputOverlaysByID.isEmpty else { return }
        guard let artboard = riveModel?.artboard else { return }
        let artboardBounds = artboard.bounds()

        // Use the same transform math as touch mapping (points, not pixels).
        let artboardToView = artboardToViewTransform(
            forArtboardRect: artboardBounds,
            fit: fit,
            alignment: alignment
        )

        for overlay in textInputOverlaysByID.values {
            // Defensive: if UIKit ever re-parents the text input view (or a
            // developer moves it), re-attach so it always follows this view's
            // transforms/layout.
            if overlay.view.superview !== self {
                addSubview(overlay.view)
            } else {
                bringSubviewToFront(overlay.view)
            }
            overlay.update(artboard: artboard, artboardToView: artboardToView)
        }
    }

    fileprivate func focusTextInputIfNeeded(at viewLocation: CGPoint) -> Bool {
        guard let artboard = riveModel?.artboard else { return false }
        guard !textInputOverlaysByID.isEmpty else { return false }

        // Convert to root artboard space to compare against text-local bounds.
        let artboardPoint = artboardLocation(
            fromTouchLocation: viewLocation,
            inArtboard: artboard.bounds(),
            fit: fit,
            alignment: alignment
        )

        for overlay in textInputOverlaysByID.values {
            if overlay.tryFocusIfHit(artboardPoint: artboardPoint) {
                return true
            }
        }
        return false
    }

    fileprivate func _focusTextInput(_ id: UUID) {
        textInputOverlaysByID[id]?.focus()
    }

    fileprivate func _blurTextInput(_ id: UUID) {
        textInputOverlaysByID[id]?.blur()
    }

    fileprivate func _removeTextInput(_ id: UUID) {
        removeTextInput(id)
    }

    #endif

    // MARK: - Debug
    
    private func setFPSCounterVisibility() {
        // Create a new counter view
        if showFPS && fpsCounter == nil {
            fpsCounter = FPSCounterView()
            addSubview(fpsCounter!)
        }
        
        if !showFPS {
            fpsCounter?.removeFromSuperview()
            fpsCounter = nil
        }
    }

    // MARK: - Private

    private func redrawIfNecessary() {
        if isPlaying == false {
            needsDisplay()
        }
    }

    private func updateLayoutScaleFactor() {
        #if os(macOS)
        guard let scale = window?.screen?.backingScaleFactor else { return }
        _layoutScaleFactor = scale
        #elseif os(visionOS)
        _layoutScaleFactor = traitCollection.displayScale
        #else
        guard let nativeScale = window?.screen.nativeScale else {
            _layoutScaleFactor = traitCollection.displayScale
            return
        }
        _layoutScaleFactor = nativeScale
        #endif
    }
}

#if canImport(UIKit)

public enum RiveTextInputKind {
    case automatic
    case singleLine
    case multiLine
}

public enum RiveTextInputRenderMode {
    case nativeRendersText
    case riveRendersText
}

public struct RiveTextInputBinding {
    public var textRunName: String
    public var path: String?
    public var kind: RiveTextInputKind
    public var renderMode: RiveTextInputRenderMode

    public var hitSlop: UIEdgeInsets
    public var focusOnTap: Bool

    public var focusBoolInputName: String?
    public var focusBoolInputPath: String?
    public var focusTriggerInputName: String?
    public var focusTriggerInputPath: String?

    public var keyboardType: UIKeyboardType
    public var returnKeyType: UIReturnKeyType
    public var textContentType: UITextContentType?
    public var autocapitalizationType: UITextAutocapitalizationType
    public var autocorrectionType: UITextAutocorrectionType
    public var spellCheckingType: UITextSpellCheckingType
    public var isSecureTextEntry: Bool

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

public enum RiveTextInputError: Error, LocalizedError {
    case textNotSupportedByBuild
    case missingArtboard
    case textRunNotFound(name: String, path: String?)
    case bindingAlreadyAttachedToAnotherView

    public var errorDescription: String? {
        switch self {
        case .textNotSupportedByBuild:
            return "Text input requires a build with WITH_RIVE_TEXT enabled."
        case .missingArtboard:
            return "No active artboard is available on this RiveView."
        case .textRunNotFound(let name, let path):
            if let path, !path.isEmpty {
                return "Could not find TextValueRun named \"\(name)\" at path \"\(path)\"."
            }
            return "Could not find TextValueRun named \"\(name)\"."
        case .bindingAlreadyAttachedToAnotherView:
            return "This text input handle is already attached to another RiveView."
        }
    }
}

public final class RiveTextInputHandle: Hashable {
    public let binding: RiveTextInputBinding
    fileprivate let id: UUID = UUID()
    fileprivate weak var riveView: RiveView?
    fileprivate weak var textInputView: UIView?

    init(binding: RiveTextInputBinding) {
        self.binding = binding
    }

    public var isEditing: Bool {
        textInputView?.isFirstResponder ?? false
    }

    @MainActor
    public func focus() {
        riveView?._focusTextInput(id)
    }

    @MainActor
    public func blur() {
        riveView?._blurTextInput(id)
    }

    @MainActor
    public func remove() {
        riveView?._removeTextInput(id)
        detach()
    }

    fileprivate func attach(to view: RiveView, textInputView: UIView) {
        self.riveView = view
        self.textInputView = textInputView
    }

    fileprivate func detach() {
        riveView = nil
        textInputView = nil
    }

    public static func == (lhs: RiveTextInputHandle, rhs: RiveTextInputHandle) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private func _riveUIColorFromARGB(_ argb: UInt32) -> UIColor {
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8) & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func _riveTextAlignment(fromRiveValue value: Int) -> NSTextAlignment {
    switch value {
    case 0: return .left
    case 1: return .right
    case 2: return .center
    default: return .natural
    }
}

private func _riveExpandedRect(_ rect: CGRect, hitSlop: UIEdgeInsets) -> CGRect {
    rect.inset(
        by: UIEdgeInsets(
            top: -hitSlop.top,
            left: -hitSlop.left,
            bottom: -hitSlop.bottom,
            right: -hitSlop.right
        )
    )
}

private final class _RiveTextField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds }
}

fileprivate final class _RiveTextInputOverlay: NSObject, UITextFieldDelegate, UITextViewDelegate {
    let handle: RiveTextInputHandle
    private weak var riveView: RiveView?

    let view: UIView
    private let textField: _RiveTextField?
    private let textView: UITextView?

    private var cachedLocalBounds: CGRect?
    private var cachedRootTransform: CGAffineTransform?

    private var isComposingText: Bool {
        if let tf = textField { return tf.markedTextRange != nil }
        if let tv = textView { return tv.markedTextRange != nil }
        return false
    }

    private var isEditing: Bool {
        view.isFirstResponder
    }

    init(handle: RiveTextInputHandle, initialRun: RiveTextValueRun, riveView: RiveView) {
        self.handle = handle
        self.riveView = riveView

        // Initial text from the run.
        let initialText = initialRun.text()

        let resolvedKind: RiveTextInputKind = {
            switch handle.binding.kind {
            case .singleLine, .multiLine:
                return handle.binding.kind
            case .automatic:
                // If the existing text contains line breaks, always use multi-line.
                if initialText.contains("\n") || initialText.contains("\r") {
                    return .multiLine
                }

                let wrap = Int(initialRun.textWrap())
                let sizing = Int(initialRun.textSizing())
                // rive::TextWrap { wrap = 0, noWrap = 1 }
                // rive::TextSizing { autoWidth = 0, autoHeight = 1, fixed = 2 }
                //
                // When sizing is autoWidth, Rive effectively has no width constraint, so
                // wrapping will not occur unless the string contains explicit line breaks.
                if wrap == 1 || sizing == 0 {
                    return .singleLine
                }
                return .multiLine
            }
        }()

	        if resolvedKind == .singleLine {
	            let tf = _RiveTextField(frame: .zero)
	            tf.borderStyle = .none
	            tf.backgroundColor = .clear
	            tf.autocapitalizationType = handle.binding.autocapitalizationType
	            tf.autocorrectionType = handle.binding.autocorrectionType
	            tf.spellCheckingType = handle.binding.spellCheckingType
	            tf.keyboardType = handle.binding.keyboardType
	            tf.returnKeyType = handle.binding.returnKeyType
            tf.textContentType = handle.binding.textContentType
            tf.isSecureTextEntry = handle.binding.isSecureTextEntry
            tf.clipsToBounds = false

            self.view = tf
            self.textField = tf
            self.textView = nil
	        } else {
	            let tv = UITextView(frame: .zero)
	            tv.backgroundColor = .clear
	            tv.autocapitalizationType = handle.binding.autocapitalizationType
	            tv.autocorrectionType = handle.binding.autocorrectionType
	            tv.spellCheckingType = handle.binding.spellCheckingType
	            tv.keyboardType = handle.binding.keyboardType
            tv.returnKeyType = handle.binding.returnKeyType
            tv.textContentType = handle.binding.textContentType
            tv.isSecureTextEntry = handle.binding.isSecureTextEntry
            tv.textContainerInset = .zero
            tv.textContainer.lineFragmentPadding = 0
            tv.clipsToBounds = false
            tv.isScrollEnabled = true

            self.view = tv
            self.textField = nil
            self.textView = tv
        }

	        super.init()
	
	        if let tf = textField {
	            tf.delegate = self
	            tf.addTarget(self, action: #selector(textFieldEditingChanged(_:)), for: .editingChanged)
	        } else if let tv = textView {
	            tv.delegate = self
	        }

        if let tf = textField {
            tf.text = initialText
        } else if let tv = textView {
            tv.text = initialText
        }

        // Default interaction strategy: click-through until editing, then allow
        // UIKit to handle selection/drag handles naturally.
        if handle.binding.focusOnTap {
            view.isUserInteractionEnabled = false
        }

        // Hook handle back to this overlay.
        handle.attach(to: riveView, textInputView: view)
    }

    func update(artboard: RiveArtboard, artboardToView: CGAffineTransform) {
        let run: RiveTextValueRun?
        if let path = handle.binding.path, !path.isEmpty {
            run = artboard.textRun(handle.binding.textRunName, path: path)
        } else {
            run = artboard.textRun(handle.binding.textRunName)
        }

        guard let run else {
            view.isHidden = true
            cachedLocalBounds = nil
            cachedRootTransform = nil
            return
        }

        view.isHidden = false

        let localBounds = run.localBounds()
        let rootTransform = run.rootShapeWorldTransform()
        cachedLocalBounds = localBounds
        cachedRootTransform = rootTransform

        // `rootTransform` maps text-local -> root artboard space.
        // `artboardToView` maps root artboard -> view (UIKit points).
        // Order matters: apply rootTransform first, then artboardToView.
        let textToView = rootTransform.concatenating(artboardToView)

        // Apply geometry.
        let w = localBounds.size.width
        let h = localBounds.size.height
        if w > 0, h > 0 {
            let centerLocal = CGPoint(x: localBounds.midX, y: localBounds.midY)
            let centerView = centerLocal.applying(textToView)
            let linear = CGAffineTransform(a: textToView.a, b: textToView.b, c: textToView.c, d: textToView.d, tx: 0, ty: 0)

            UIView.performWithoutAnimation {
                view.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                view.transform = linear
                view.center = centerView
            }
        }

        if handle.binding.mirrorStyleFromRive {
            applyStyle(from: run)
        }

        // Ensure renderMode always applies even if style mirroring is disabled.
        applyRenderModeVisibility()

        // Apply developer overrides last.
        if let override = handle.binding.styleOverride, let traitsView = view as? (UIView & UITextInputTraits) {
            Task { @MainActor in
                override(traitsView)
            }
        }

        // Sync native text from Rive only when not editing and not composing.
        if !isEditing && !isComposingText {
            let riveText = run.text()
            if let tf = textField, tf.text != riveText {
                tf.text = riveText
            } else if let tv = textView, tv.text != riveText {
                tv.text = riveText
            }
        }
    }

    private func applyRenderModeVisibility() {
        guard handle.binding.renderMode == .riveRendersText else { return }

        // Don't set alpha to 0; UIKit skips hit testing for near-transparent views.
        let invisible = UIColor.clear

        if let tf = textField {
            tf.textColor = invisible

            var attrs = tf.defaultTextAttributes
            attrs[.foregroundColor] = invisible
            tf.defaultTextAttributes = attrs
        } else if let tv = textView {
            tv.textColor = invisible

            var attrs = tv.typingAttributes
            attrs[.foregroundColor] = invisible
            tv.typingAttributes = attrs
        }
    }

    func tryFocusIfHit(artboardPoint: CGPoint) -> Bool {
        guard handle.binding.focusOnTap else { return false }
        guard !isEditing else { return false }
        guard let localBounds = cachedLocalBounds, let rootTransform = cachedRootTransform else { return false }

        let det = rootTransform.a * rootTransform.d - rootTransform.b * rootTransform.c
        if abs(det) < 1e-6 {
            return false
        }

        let localPoint = artboardPoint.applying(rootTransform.inverted())
        let hitRect = _riveExpandedRect(localBounds, hitSlop: handle.binding.hitSlop)
        guard hitRect.contains(localPoint) else { return false }

        focus()
        return true
    }

    func focus() {
        // Once focused, allow UIKit to handle editing gestures.
        view.isUserInteractionEnabled = true

        if view.canBecomeFirstResponder {
            _ = view.becomeFirstResponder()
        }
    }

    func blur() {
        _ = view.resignFirstResponder()
    }

    private func applyStyle(from run: RiveTextValueRun) {
        let fontSize = CGFloat(run.fontSize())
        let lineHeight = CGFloat(run.lineHeight())
        let letterSpacing = CGFloat(run.letterSpacing())
        let align = Int(run.textAlign())
        let overflow = Int(run.textOverflow())

        let existingFont = (textField?.font ?? textView?.font)
        let desiredFontSize: CGFloat
        if fontSize > 0 {
            desiredFontSize = fontSize
        } else if let existingFont {
            desiredFontSize = existingFont.pointSize
        } else {
            desiredFontSize = UIFont.systemFontSize
        }

        let variationKey = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let wghtTag: UInt32 = 0x77676874 // "wght"

        // Prefer the exact font embedded in the .riv file if it was registered
        // via CoreText during asset load. If the embedded font is variable,
        // also apply the current weight axis ("wght") so UIKit matches Rive's
        // shaping/metrics.
        let baseFont: UIFont = {
            let fontKey = run.fontAssetKey()
            if !fontKey.isEmpty,
               let postScriptName = RiveFontAssetRegistry.postScriptName(forAssetKey: fontKey as NSString) as String?,
               let base = UIFont(name: postScriptName, size: desiredFontSize) {

                let wght = CGFloat(run.fontWeight())
                if wght.isFinite, wght > 0 {
                    let clamped = max(1, min(1000, wght))
                    var variations = (base.fontDescriptor.object(forKey: variationKey) as? [NSNumber: Any]) ?? [:]
                    variations[NSNumber(value: wghtTag)] = NSNumber(value: Double(clamped))

                    let desc = base.fontDescriptor.addingAttributes([variationKey: variations])
                    return UIFont(descriptor: desc, size: desiredFontSize)
                }

                return base
            }

            if let existingFont {
                return existingFont.withSize(desiredFontSize)
            }
            return UIFont.systemFont(ofSize: desiredFontSize)
        }()

        let riveColorARGB = run.solidFillColorARGB()
        let baseColor: UIColor = (riveColorARGB != 0) ? _riveUIColorFromARGB(riveColorARGB) : .label

        let textColor: UIColor
        switch handle.binding.renderMode {
        case .nativeRendersText:
            textColor = baseColor
        case .riveRendersText:
            textColor = .clear
        }

        let tintColor: UIColor = (riveColorARGB != 0) ? baseColor : .systemBlue

        let alignment = _riveTextAlignment(fromRiveValue: align)

        view.clipsToBounds = overflow != 0 // overflow != visible

        if let tf = textField {
            tf.font = baseFont
            tf.textAlignment = alignment
            tf.textColor = textColor
            tf.tintColor = tintColor

            var attrs = tf.defaultTextAttributes
            attrs[.font] = baseFont
            attrs[.foregroundColor] = textColor
            if letterSpacing != 0 {
                attrs[.kern] = letterSpacing
            } else {
                attrs.removeValue(forKey: .kern)
            }
            if lineHeight > 0 {
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = lineHeight
                p.maximumLineHeight = lineHeight
                attrs[.paragraphStyle] = p
            } else {
                attrs.removeValue(forKey: .paragraphStyle)
            }
            tf.defaultTextAttributes = attrs
        } else if let tv = textView {
            tv.font = baseFont
            tv.textAlignment = alignment
            tv.textColor = textColor
            tv.tintColor = tintColor

            var attrs = tv.typingAttributes
            attrs[.font] = baseFont
            attrs[.foregroundColor] = textColor
            if letterSpacing != 0 {
                attrs[.kern] = letterSpacing
            } else {
                attrs.removeValue(forKey: .kern)
            }
            if lineHeight > 0 {
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = lineHeight
                p.maximumLineHeight = lineHeight
                attrs[.paragraphStyle] = p
            } else {
                attrs.removeValue(forKey: .paragraphStyle)
            }
            tv.typingAttributes = attrs
        }
    }

    private func propagateTextChange() {
        guard let riveView = riveView else { return }

        let text: String
        if let tf = textField {
            text = tf.text ?? ""
        } else if let tv = textView {
            text = tv.text ?? ""
        } else {
            return
        }

        #if WITH_RIVE_TEXT
        guard let artboard = riveView.riveModel?.artboard else { return }
        let run: RiveTextValueRun?
        if let path = handle.binding.path, !path.isEmpty {
            run = artboard.textRun(handle.binding.textRunName, path: path)
        } else {
            run = artboard.textRun(handle.binding.textRunName)
        }
        run?.setText(text)

        // Ensure the artboard processes the text dirt immediately so the UIKit
        // view can be resized before it reflows/wraps the newly inserted text.
        artboard.advance(by: 0)

        riveView.updateTextInputOverlays()

        if let tv = textView {
            tv.layoutManager.ensureLayout(for: tv.textContainer)
        }

        if riveView.isPlaying == false {
            riveView.advance(delta: 0)
        } else {
            riveView.setNeedsDisplay()
        }
        #endif

        riveView.textInputDelegate?.riveTextInputDidChange(handle)
    }

    private func setFocusInputs(isFocused: Bool) {
        guard let riveView = riveView else { return }
        guard let artboard = riveView.riveModel?.artboard else { return }

        if let boolName = handle.binding.focusBoolInputName {
            let path = handle.binding.focusBoolInputPath ?? ""
            artboard.getBool(boolName, path: path).setValue(isFocused)
            riveView.play()
        }

        if isFocused, let triggerName = handle.binding.focusTriggerInputName {
            let path = handle.binding.focusTriggerInputPath ?? ""
            artboard.getTrigger(triggerName, path: path).fire()
            riveView.play()
        }
    }

    // MARK: UITextField

    @objc private func textFieldEditingChanged(_ sender: UITextField) {
        propagateTextChange()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        setFocusInputs(isFocused: true)
        riveView?.textInputDelegate?.riveTextInputDidBeginEditing(handle)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        setFocusInputs(isFocused: false)

        if handle.binding.focusOnTap {
            view.isUserInteractionEnabled = false
        }

        riveView?.textInputDelegate?.riveTextInputDidEndEditing(handle)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        riveView?.textInputDelegate?.riveTextInputDidSubmit(handle)
        textField.resignFirstResponder()
        return false
    }

    // MARK: UITextView

    func textViewDidBeginEditing(_ textView: UITextView) {
        setFocusInputs(isFocused: true)
        riveView?.textInputDelegate?.riveTextInputDidBeginEditing(handle)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        setFocusInputs(isFocused: false)

        if handle.binding.focusOnTap {
            view.isUserInteractionEnabled = false
        }

        riveView?.textInputDelegate?.riveTextInputDidEndEditing(handle)
    }

    func textViewDidChange(_ textView: UITextView) {
        propagateTextChange()
    }
}

#endif

/// An enum of possible touch or mouse events when interacting with an animation.
@objc public enum RiveTouchEvent: Int {
    /// The touch event that occurs when a touch or mouse button click occurs.
    case began
    /// The touch event that occurs when a touch or mouse is dragged.
    case moved
    /// The touch event that occurs when a touch or mouse button is lifted.
    case ended
    /// The touch event that occurs when a touch or mouse click is cancelled.
    case cancelled
    /// The touch event that occurs when a touch exits the artboard; specifically used when multitouch is enabled
    /// This event is triggered when a touch leaves the artboard area during multitouch interactions
    case exited
}

@objc public protocol RiveStateMachineDelegate: AnyObject {
    @objc optional func touchBegan(onArtboard artboard: RiveArtboard?, atLocation location: CGPoint)
    @objc optional func touchMoved(onArtboard artboard: RiveArtboard?, atLocation location: CGPoint)
    @objc optional func touchEnded(onArtboard artboard: RiveArtboard?, atLocation location: CGPoint)
    @objc optional func touchCancelled(onArtboard artboard: RiveArtboard?, atLocation location: CGPoint)
    /// Called when a touch exits the artboard, typically used for multitouch scenarios
    /// @param artboard The artboard where the touch exited
    /// @param location The location where the touch exited in artboard coordinates
    @objc optional func touchExited(onArtboard artboard: RiveArtboard?, atLocation location: CGPoint)

    @objc optional func stateMachine(_ stateMachine: RiveStateMachineInstance, receivedInput input: StateMachineInput)
    @objc optional func stateMachine(_ stateMachine: RiveStateMachineInstance, didChangeState stateName: String)
    @objc optional func stateMachine(_ stateMachine: RiveStateMachineInstance, didReceiveHitResult hitResult: RiveHitResult, from event: RiveTouchEvent)
    @objc optional func onRiveEventReceived(onRiveEvent riveEvent: RiveEvent)
}

@objc public protocol RivePlayerDelegate: AnyObject {
    func player(playedWithModel riveModel: RiveModel?)
    func player(pausedWithModel riveModel: RiveModel?)
    func player(loopedWithModel riveModel: RiveModel?, type: Int)
    func player(stoppedWithModel riveModel: RiveModel?)
    func player(didAdvanceby seconds: Double, riveModel: RiveModel?)
}

/// Tracks a queue of events that haven't been fired yet. We do this so that we're not calling delegates and modifying state
/// while a view is updating (e.g. being initialized, as we autoplay and fire play events during the view's init otherwise
class EventQueue {
    var events: [() -> Void] = []

    func add(_ event: @escaping () -> Void) {
        events.append(event)
    }

    func fireAll() {
        events.forEach { $0() }
        events.removeAll()
    }
}
