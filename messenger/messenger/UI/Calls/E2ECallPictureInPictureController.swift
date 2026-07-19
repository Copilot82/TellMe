import AVFoundation
@preconcurrency import AVKit
import UIKit
import WebRTC

private enum ContentSourceMode: String {
  case videoCall = "video_call"
  case sampleBufferLayer = "sample_buffer_layer"

  private static let environmentKey: String = "E2E_CALL_PIP_SOURCE_MODE"

  static func resolved(from override: String?) -> ContentSourceMode {
    let rawValue: String = (override ?? ProcessInfo.processInfo.environment[environmentKey] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch rawValue {
    case "video_call", "video-call", "videocall":
      return .videoCall
    case "sample_buffer_layer", "sample-buffer-layer", "samplebufferlayer", "layer":
      return .sampleBufferLayer
    default:
      return .videoCall
    }
  }
}

@MainActor
// PiP owns its sample-buffer source independently from inline rendering to avoid renderer lifetime coupling.
final class E2ECallPictureInPictureController: NSObject {
  private weak var session: E2ECallSessionViewModel?
  private var sourceView: UIView?
  private var pictureInPictureController: AVPictureInPictureController?
  private var contentViewController: AVPictureInPictureVideoCallViewController?
  private var sampleBufferVideoRenderer: E2ECallSampleBufferVideoRenderer?
  private var remoteVideoRenderer: RTCVideoRenderer?
  private var pictureInPicturePossibleObservation: NSKeyValueObservation?
  private var sampleBufferDisplayConstraints: [NSLayoutConstraint] = []
  private var isRendererAttached: Bool = false
  private var hasStartRequestInFlight: Bool = false
  private var hasDeferredStartRequest: Bool = false
  private var contentSourceKind: String = "none"
  private var sampleBufferDisplayHost: String = "none"
  private var startRequestWatchdogWorkItem: DispatchWorkItem?
  private var delayedStartWorkItem: DispatchWorkItem?
  private var automaticStartWatchdogWorkItem: DispatchWorkItem?
  private var pictureInPictureActiveObservation: NSKeyValueObservation?
  private var timedOutStartRequestCount: Int = 0
  private var lastManualStartAt: Date?
  private var lastAutomaticStartPreparedAt: Date?
  private var lastStartDiagnosticContext: String = "none"
  private var lastAutomaticStartDiagnosticContext: String = "none"
  private var lastFailureDiagnosticContext: String = "none"
  private var lastPossibleDiagnosticContext: String = "unknown"
  private var lastInferredBlocker: String = "none"
  private let startRequestWatchdogDelayNanoseconds: UInt64
  private let automaticStartWatchdogDelayNanoseconds: UInt64 = 1_500_000_000
  private let preferredVideoCallContentSize: CGSize = CGSize(width: 180, height: 320)
  private let minimumPlaceholderShortSide: CGFloat = 180
  private let configuredContentSourceMode: ContentSourceMode

  init(
    session: E2ECallSessionViewModel,
    startRequestWatchdogDelayNanoseconds: UInt64 = 1_000_000_000,
    contentSourceModeOverride: String? = nil
  ) {
    self.session = session
    self.startRequestWatchdogDelayNanoseconds = startRequestWatchdogDelayNanoseconds
    self.configuredContentSourceMode = ContentSourceMode.resolved(from: contentSourceModeOverride)
    super.init()
  }

  var isAvailable: Bool {
    AVPictureInPictureController.isPictureInPictureSupported() && pictureInPictureController != nil
  }

  var isActive: Bool {
    pictureInPictureController?.isPictureInPictureActive == true
  }

  var diagnosticsSummary: String {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      return "unsupported"
    }

    guard let controller: AVPictureInPictureController = pictureInPictureController else {
      return "not_configured"
    }

    var components: [String] = [
      "configured",
      "possible=\(controller.isPictureInPicturePossible)",
      "active=\(controller.isPictureInPictureActive)",
      "auto=\(controller.canStartPictureInPictureAutomaticallyFromInline)",
      "inflight=\(hasStartRequestInFlight)",
      "deferred=\(hasDeferredStartRequest)",
      "lastStart=\(compactDiagnostic(lastStartDiagnosticContext))",
      "lastAuto=\(diagnosticContextWithAge(lastAutomaticStartDiagnosticContext, since: lastAutomaticStartPreparedAt))",
      "lastFailure=\(compactDiagnostic(lastFailureDiagnosticContext))",
      "possibleState=\(compactDiagnostic(lastPossibleDiagnosticContext))",
      "inferred=\(compactDiagnostic(lastInferredBlocker))",
      "renderer=\(isRendererAttached)",
      "sampleBuffer=\(sampleBufferVideoRenderer != nil)",
      "source=\(contentSourceKind)",
      "host=\(sampleBufferDisplayHost)",
      "sourceView=\(sourceViewDiagnosticsSummary)",
      "content=\(contentViewDiagnosticsSummary)",
      "layer=\(sampleBufferLayerDiagnosticsSummary)",
      "system=\(runtimeDiagnosticsSummary)",
      "callkit=\(SystemCallCoordinator.shared.diagnosticsSummary())",
    ]
#if DEBUG
    components.append("sampled=\(sampleBufferVideoRenderer?.sampleBufferFrameCountForTesting ?? 0)")
    components.append("frames=\(sampleBufferVideoRenderer?.enqueuedFrameCountForTesting ?? 0)")
    components.append("drops=\(sampleBufferVideoRenderer?.droppedFrameCountForTesting ?? 0)")
#endif
    return components.joined(separator: "/")
  }

#if DEBUG
  var isRendererAttachedForTesting: Bool {
    isRendererAttached
  }

  var hasStartRequestInFlightForTesting: Bool {
    hasStartRequestInFlight
  }

  var hasDeferredStartRequestForTesting: Bool {
    hasDeferredStartRequest
  }

  func installRemoteVideoRendererForTesting(_ renderer: RTCVideoRenderer) {
    remoteVideoRenderer = renderer
  }

  var sampleBufferVideoRendererForTesting: E2ECallSampleBufferVideoRenderer? {
    sampleBufferVideoRenderer
  }

  var contentSourceKindForTesting: String {
    contentSourceKind
  }

  var sampleBufferDisplayHostForTesting: String {
    sampleBufferDisplayHost
  }

  var sampleBufferDisplaySuperviewForTesting: UIView? {
    sampleBufferVideoRenderer?.displayView.superview
  }

  var sourceViewForTesting: UIView? {
    sourceView
  }

  func beginStartRequestForTesting(isActive: Bool, isPossible: Bool) -> Bool {
    beginStartRequestIfAllowed(isActive: isActive, isPossible: isPossible)
  }

  func startIfPossibleForTesting(
    isActive: Bool,
    isPossible: Bool,
    source: String = "test",
    startPictureInPicture: () -> Void = {}
  ) -> Bool {
    startIfPossible(
      isActive: isActive,
      isPossible: isPossible,
      source: source,
      startPictureInPicture: startPictureInPicture
    )
  }

  func startDeferredRequestIfPossibleForTesting(
    isActive: Bool,
    isPossible: Bool,
    source: String = "test_deferred",
    startPictureInPicture: () -> Void = {}
  ) -> Bool {
    startDeferredRequestIfPossible(
      isActive: isActive,
      isPossible: isPossible,
      source: source,
      startPictureInPicture: startPictureInPicture
    )
  }

  func fireStartRequestWatchdogForTesting(
    isActive: Bool = false,
    isPossible: Bool = true
  ) {
    startRequestWatchdogWorkItem = nil
    guard hasStartRequestInFlight else {
      return
    }

    handleStartRequestWatchdogTimeout(
      isActive: isActive,
      isPossible: isPossible
    )
  }
#endif

  func configure(sourceView: UIView) {
    let activeSourceView: UIView = activeVideoCallSourceView(preferredSourceView: sourceView)
    let previousSourceView: UIView? = self.sourceView
    let previousContentSourceKind: String = contentSourceKind
    let requestedContentSourceKind: String = configuredContentSourceMode.rawValue
    self.sourceView = activeSourceView

    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      trace("call_pip_unsupported")
      return
    }

    if configuredContentSourceMode == .videoCall,
      !isReadyVideoCallSourceView(activeSourceView)
    {
      trace(
        "call_pip_configure_deferred_source_not_ready",
        detail: videoCallSourceReadinessDiagnostics(activeSourceView)
      )
      return
    }

    let sampleBufferRenderer: E2ECallSampleBufferVideoRenderer
    if let existingRenderer: E2ECallSampleBufferVideoRenderer = sampleBufferVideoRenderer {
      sampleBufferRenderer = existingRenderer
    } else {
      sampleBufferRenderer = E2ECallSampleBufferVideoRenderer()
      sampleBufferRenderer.displayView.translatesAutoresizingMaskIntoConstraints = false
      sampleBufferVideoRenderer = sampleBufferRenderer
    }
    remoteVideoRenderer = sampleBufferRenderer
    let preferredSize: CGSize = preferredContentSize(for: activeSourceView)
    sampleBufferRenderer.enqueuePlaceholderFrameIfNeeded(size: placeholderFrameSize(for: preferredSize))

    let contentController: AVPictureInPictureVideoCallViewController
    if let existingContentController: AVPictureInPictureVideoCallViewController = contentViewController {
      contentController = existingContentController
      contentController.preferredContentSize = preferredSize
    } else {
      contentController = AVPictureInPictureVideoCallViewController()
      contentController.view.backgroundColor = .black
      contentViewController = contentController
    }
    contentController.preferredContentSize = preferredSize
    if contentController.view.bounds.width < 1 || contentController.view.bounds.height < 1 {
      contentController.view.frame = CGRect(origin: .zero, size: preferredSize)
      contentController.view.bounds = CGRect(origin: .zero, size: preferredSize)
    }

    let contentSource: AVPictureInPictureController.ContentSource
    switch configuredContentSourceMode {
    case .videoCall:
      installSampleBufferDisplay(in: contentController.view, host: "content")
      contentSource = AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: activeSourceView,
        contentViewController: contentController
      )
    case .sampleBufferLayer:
      installSampleBufferDisplay(in: activeSourceView, host: "source")
      contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: sampleBufferRenderer.displayView.sampleBufferDisplayLayer,
        playbackDelegate: self
      )
    }
    contentSourceKind = requestedContentSourceKind

    if let controller: AVPictureInPictureController = pictureInPictureController {
      let shouldReuseExistingContentSource: Bool =
        previousSourceView === activeSourceView
        && previousContentSourceKind == requestedContentSourceKind
      if shouldReuseExistingContentSource {
        prepareRendererForPictureInPicture()
        trace(
          "call_pip_reconfigure_reused",
          detail: diagnosticContext(
            source: "reconfigure_reuse",
            controller: controller,
            isActive: controller.isPictureInPictureActive,
            isPossible: controller.isPictureInPicturePossible
          )
        )
        scheduleDeferredStartIfNeeded(controller)
        return
      }

      let shouldSkipReconfigure: Bool =
        hasStartRequestInFlight
        || controller.isPictureInPictureActive
        || UIApplication.shared.applicationState != .active
      guard !shouldSkipReconfigure else {
        prepareRendererForPictureInPicture()
        trace(
          "call_pip_reconfigure_skipped",
          detail: diagnosticContext(
            source: "reconfigure_skip",
            controller: controller,
            isActive: controller.isPictureInPictureActive,
            isPossible: controller.isPictureInPicturePossible
          )
        )
        return
      }

      controller.contentSource = contentSource
      prepareRendererForPictureInPicture()
      trace(
        "call_pip_reconfigured",
        detail: diagnosticContext(
          source: "reconfigure",
          controller: controller,
          isActive: controller.isPictureInPictureActive,
          isPossible: controller.isPictureInPicturePossible
        )
      )
      scheduleDeferredStartIfNeeded(controller)
      return
    }

    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.delegate = self
    pictureInPictureController = controller
    observePictureInPictureState(controller)
    prepareRendererForPictureInPicture()
    trace(
      "call_pip_configured",
      detail: diagnosticContext(
        source: "configured",
        controller: controller,
        isActive: controller.isPictureInPictureActive,
        isPossible: controller.isPictureInPicturePossible
      )
    )
    scheduleDeferredStartIfNeeded(controller)
  }

  func prepareForAutomaticStart(reason: String = "unknown") {
    guard let controller: AVPictureInPictureController = pictureInPictureController else {
      lastFailureDiagnosticContext = "auto_prepare_without_controller,reason=\(reason),\(runtimeDiagnosticsSummary)"
      lastInferredBlocker = "pip_controller_not_configured_for_auto_start"
      trace("call_pip_auto_background_wait", detail: lastFailureDiagnosticContext)
      return
    }

    attachRendererIfNeeded()
    hasDeferredStartRequest = false
    lastAutomaticStartPreparedAt = Date()
    lastAutomaticStartDiagnosticContext = diagnosticContext(
      source: "auto_\(reason)",
      controller: controller,
      isActive: controller.isPictureInPictureActive,
      isPossible: controller.isPictureInPicturePossible
    )
    lastInferredBlocker = "automatic_start_armed"
    trace(
      "call_pip_auto_background_wait",
      detail: lastAutomaticStartDiagnosticContext
    )
    startAutomaticBackgroundPictureInPictureIfPossible(controller, reason: reason)
    scheduleAutomaticStartWatchdog(controller, reason: reason)
  }

  func startIfPossible(source: String = "manual") -> Bool {
    guard let controller: AVPictureInPictureController = pictureInPictureController else {
      lastFailureDiagnosticContext = "manual_start_without_controller,source=\(source),\(runtimeDiagnosticsSummary)"
      lastInferredBlocker = "pip_controller_not_configured_for_manual_start"
      trace("call_pip_start_without_controller", detail: lastFailureDiagnosticContext)
      return false
    }

    let didStart: Bool = startIfPossible(
      isActive: controller.isPictureInPictureActive,
      isPossible: controller.isPictureInPicturePossible,
      source: source,
      startPictureInPicture: {
        controller.startPictureInPicture()
      }
    )
    if !didStart {
      scheduleDeferredStartIfNeeded(controller)
    }
    return didStart
  }

  private func startIfPossible(
    isActive: Bool,
    isPossible: Bool,
    source: String,
    startPictureInPicture: () -> Void
  ) -> Bool {
    if isActive || hasStartRequestInFlight {
      hasDeferredStartRequest = false
      attachRendererIfNeeded()
      trace(
        "call_pip_start_reused",
        detail: diagnosticContext(
          source: source,
          controller: pictureInPictureController,
          isActive: isActive,
          isPossible: isPossible
        )
      )
      return true
    }

    guard isPossible else {
      hasDeferredStartRequest = true
      attachRendererIfNeeded()
      lastInferredBlocker = "pip_not_possible_at_manual_start"
      trace(
        "call_pip_start_deferred",
        detail: diagnosticContext(
          source: source,
          controller: pictureInPictureController,
          isActive: isActive,
          isPossible: isPossible
        )
      )
      return false
    }

    guard beginStartRequestIfAllowed(isActive: isActive, isPossible: isPossible) else {
      trace(
        "call_pip_start_rejected",
        detail: diagnosticContext(
          source: source,
          controller: pictureInPictureController,
          isActive: isActive,
          isPossible: isPossible
        )
      )
      return false
    }

    hasDeferredStartRequest = false
    attachRendererIfNeeded()
    lastManualStartAt = Date()
    lastStartDiagnosticContext = diagnosticContext(
      source: source,
      controller: pictureInPictureController,
      isActive: isActive,
      isPossible: isPossible
    )
    lastInferredBlocker = "manual_start_waiting_for_avkit_delegate"
    trace("call_pip_start_begin", detail: lastStartDiagnosticContext)
    startPictureInPicture()
    scheduleStartRequestWatchdog()
    return true
  }

  private func observePictureInPictureState(_ controller: AVPictureInPictureController) {
    pictureInPicturePossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self, weak controller] _, change in
      Task { @MainActor [weak self, weak controller] in
        guard let self,
          let controller
        else {
          return
        }

        let isPossible: Bool = change.newValue ?? controller.isPictureInPicturePossible
        self.lastPossibleDiagnosticContext = self.diagnosticContext(
          source: "possible_changed",
          controller: controller,
          isActive: controller.isPictureInPictureActive,
          isPossible: isPossible
        )
        self.trace("call_pip_possible_changed", detail: self.lastPossibleDiagnosticContext)
        if isPossible {
          self.scheduleDeferredStartIfNeeded(controller)
        } else {
          self.lastInferredBlocker = "pip_possible_false"
        }
      }
    }
    pictureInPictureActiveObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) {
      [weak self, weak controller] _, change in
      Task { @MainActor [weak self, weak controller] in
        guard let self,
          let controller
        else {
          return
        }

        let isActive: Bool = change.newValue ?? controller.isPictureInPictureActive
        self.trace(
          "call_pip_active_changed",
          detail: self.diagnosticContext(
            source: "active_changed",
            controller: controller,
            isActive: isActive,
            isPossible: controller.isPictureInPicturePossible
          )
        )
        guard isActive else {
          return
        }

        self.cancelStartRequestWatchdog()
        self.cancelAutomaticStartWatchdog()
        self.delayedStartWorkItem?.cancel()
        self.delayedStartWorkItem = nil
        self.attachRendererIfNeeded()
        self.hasDeferredStartRequest = false
        self.hasStartRequestInFlight = false
        self.timedOutStartRequestCount = 0
        self.lastInferredBlocker = "none"
        self.session?.notifyPictureInPictureDidStart()
      }
    }
  }

  private func scheduleDeferredStartIfNeeded(_ controller: AVPictureInPictureController) {
    guard hasDeferredStartRequest else {
      return
    }

    delayedStartWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self, weak controller] in
      Task { @MainActor [weak self, weak controller] in
        guard let self,
          let controller
        else {
          return
        }

        self.trace(
          "call_pip_deferred_start_tick",
          detail: "possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive)"
        )
        _ = self.startDeferredRequestIfPossible(
          isActive: controller.isPictureInPictureActive,
          isPossible: controller.isPictureInPicturePossible,
          source: "deferred_possible_tick",
          startPictureInPicture: {
            controller.startPictureInPicture()
          }
        )
      }
    }
    delayedStartWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
  }

  private func startDeferredRequestIfPossible(
    isActive: Bool,
    isPossible: Bool,
    source: String,
    startPictureInPicture: () -> Void
  ) -> Bool {
    guard hasDeferredStartRequest else {
      return false
    }

    return startIfPossible(
      isActive: isActive,
      isPossible: isPossible,
      source: source,
      startPictureInPicture: startPictureInPicture
    )
  }

  private func startAutomaticBackgroundPictureInPictureIfPossible(
    _ controller: AVPictureInPictureController,
    reason: String
  ) {
    guard !controller.isPictureInPictureActive,
      controller.isPictureInPicturePossible
    else {
      return
    }

    _ = startIfPossible(
      isActive: controller.isPictureInPictureActive,
      isPossible: controller.isPictureInPicturePossible,
      source: "auto_background_\(reason)",
      startPictureInPicture: {
        controller.startPictureInPicture()
      }
    )
  }

  func stopAndRelease() {
    if pictureInPictureController?.isPictureInPictureActive == true {
      pictureInPictureController?.stopPictureInPicture()
    }

    pictureInPicturePossibleObservation = nil
    pictureInPictureActiveObservation = nil
    pictureInPictureController?.delegate = nil
    pictureInPictureController?.contentSource = nil
    pictureInPictureController = nil
    hasStartRequestInFlight = false
    hasDeferredStartRequest = false
    contentSourceKind = "none"
    sampleBufferDisplayHost = "none"
    timedOutStartRequestCount = 0
    delayedStartWorkItem?.cancel()
    delayedStartWorkItem = nil
    cancelStartRequestWatchdog()
    cancelAutomaticStartWatchdog()
    detachRendererIfNeeded()
    sampleBufferVideoRenderer?.flush()
    NSLayoutConstraint.deactivate(sampleBufferDisplayConstraints)
    sampleBufferDisplayConstraints.removeAll()
    sampleBufferVideoRenderer?.displayView.removeFromSuperview()
    sampleBufferVideoRenderer = nil
    remoteVideoRenderer = nil
    contentViewController = nil
    sourceView = nil
  }

  private func beginStartRequestIfAllowed(isActive: Bool, isPossible: Bool) -> Bool {
    guard !hasStartRequestInFlight, !isActive, isPossible else {
      return false
    }

    hasStartRequestInFlight = true
    return true
  }

  private func scheduleStartRequestWatchdog() {
    cancelStartRequestWatchdog()
    let delay: UInt64 = startRequestWatchdogDelayNanoseconds
    let workItem = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleStartRequestWatchdogTimeout()
      }
    }
    startRequestWatchdogWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Double(delay) / 1_000_000_000,
      execute: workItem
    )
  }

  private func cancelStartRequestWatchdog() {
    startRequestWatchdogWorkItem?.cancel()
    startRequestWatchdogWorkItem = nil
  }

  private func scheduleAutomaticStartWatchdog(_ controller: AVPictureInPictureController, reason: String) {
    cancelAutomaticStartWatchdog()
    let preparedAt: Date = Date()
    lastAutomaticStartPreparedAt = preparedAt
    let delay: UInt64 = automaticStartWatchdogDelayNanoseconds
    let workItem = DispatchWorkItem { [weak self, weak controller] in
      Task { @MainActor [weak self, weak controller] in
        guard let self,
          let controller
        else {
          return
        }

        self.handleAutomaticStartWatchdogTimeout(
          controller: controller,
          reason: reason,
          preparedAt: preparedAt
        )
      }
    }
    automaticStartWatchdogWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Double(delay) / 1_000_000_000,
      execute: workItem
    )
  }

  private func cancelAutomaticStartWatchdog() {
    automaticStartWatchdogWorkItem?.cancel()
    automaticStartWatchdogWorkItem = nil
  }

  private func handleAutomaticStartWatchdogTimeout(
    controller: AVPictureInPictureController,
    reason: String,
    preparedAt: Date
  ) {
    automaticStartWatchdogWorkItem = nil
    guard pictureInPictureController === controller else {
      return
    }

    let elapsedSeconds: String = String(format: "%.1f", Date().timeIntervalSince(preparedAt))
    let detail: String = diagnosticContext(
      source: "auto_watchdog_\(reason),elapsed=\(elapsedSeconds)s",
      controller: controller,
      isActive: controller.isPictureInPictureActive,
      isPossible: controller.isPictureInPicturePossible
    )

    if controller.isPictureInPictureActive {
      lastInferredBlocker = "none"
      trace("call_pip_auto_background_started_late", detail: detail)
      return
    }

    let applicationState: UIApplication.State = UIApplication.shared.applicationState
    if applicationState == .active {
      lastInferredBlocker = "auto_start_watchdog_only_ran_after_foreground"
    } else if controller.isPictureInPicturePossible {
      lastInferredBlocker = "system_auto_start_not_observed"
    } else {
      lastInferredBlocker = "pip_not_possible_when_auto_start_checked"
    }
    lastFailureDiagnosticContext = "auto_no_start,\(detail)"
    trace("call_pip_auto_background_no_start", detail: detail)
  }

  private func handleStartRequestWatchdogTimeout() {
    startRequestWatchdogWorkItem = nil

    guard hasStartRequestInFlight else {
      return
    }

    guard let controller: AVPictureInPictureController = pictureInPictureController else {
      hasStartRequestInFlight = false
      hasDeferredStartRequest = false
      lastFailureDiagnosticContext = "manual_watchdog_without_controller,\(runtimeDiagnosticsSummary)"
      lastInferredBlocker = "pip_controller_released_during_manual_start"
      trace("call_pip_start_timed_out", detail: lastFailureDiagnosticContext)
      prepareRendererForPictureInPicture()
      session?.notifyPictureInPictureStartFailed()
      return
    }

    handleStartRequestWatchdogTimeout(
      isActive: controller.isPictureInPictureActive,
      isPossible: controller.isPictureInPicturePossible
    )
  }

  private func handleStartRequestWatchdogTimeout(
    isActive: Bool,
    isPossible: Bool
  ) {
    if isActive {
      hasStartRequestInFlight = false
      hasDeferredStartRequest = false
      delayedStartWorkItem?.cancel()
      delayedStartWorkItem = nil
      timedOutStartRequestCount = 0
      attachRendererIfNeeded()
      trace("call_pip_start_watchdog_active")
      session?.notifyPictureInPictureDidStart()
      return
    }

    timedOutStartRequestCount += 1
    hasStartRequestInFlight = false
    hasDeferredStartRequest = false
    lastFailureDiagnosticContext = diagnosticContext(
      source: "manual_watchdog_timeout,attempt=\(timedOutStartRequestCount)",
      controller: pictureInPictureController,
      isActive: isActive,
      isPossible: isPossible
    )
    lastInferredBlocker = "manual_start_no_avkit_delegate_callback"
    trace(
      "call_pip_start_timed_out",
      detail: lastFailureDiagnosticContext
    )
    resetPictureInPictureControllerAfterSilentStartTimeout(
      shouldRetryBackgroundStart: isPossible
        && UIApplication.shared.applicationState != .active
        && timedOutStartRequestCount == 1
    )
    prepareRendererForPictureInPicture()
    session?.notifyPictureInPictureStartFailed()
  }

  private func resetPictureInPictureControllerAfterSilentStartTimeout(
    shouldRetryBackgroundStart: Bool
  ) {
    guard let sourceView else {
      trace(
        "call_pip_controller_reset_skipped",
        detail: "reason=missing_source_after_timeout,\(runtimeDiagnosticsSummary)"
      )
      return
    }

    let previousController: AVPictureInPictureController? = pictureInPictureController
    let detail: String = diagnosticContext(
      source: "reset_after_timeout,retry=\(shouldRetryBackgroundStart)",
      controller: previousController,
      isActive: previousController?.isPictureInPictureActive ?? false,
      isPossible: previousController?.isPictureInPicturePossible ?? false
    )

    pictureInPicturePossibleObservation = nil
    pictureInPictureActiveObservation = nil
    previousController?.delegate = nil
    previousController?.contentSource = nil
    pictureInPictureController = nil
    contentSourceKind = "none"
    delayedStartWorkItem?.cancel()
    delayedStartWorkItem = nil
    cancelAutomaticStartWatchdog()
    if shouldRetryBackgroundStart {
      hasDeferredStartRequest = true
    }

    trace("call_pip_controller_reset_after_timeout", detail: detail)
    configure(sourceView: sourceView)

    if shouldRetryBackgroundStart,
      let controller: AVPictureInPictureController = pictureInPictureController
    {
      scheduleDeferredStartIfNeeded(controller)
    }
  }

  private func attachRendererIfNeeded() {
    guard !isRendererAttached, let remoteVideoRenderer else {
      return
    }

    session?.attachAdditionalRemoteVideoRenderer(remoteVideoRenderer)
    isRendererAttached = true
  }

  private func prepareRendererForPictureInPicture() {
    let wasAttached: Bool = isRendererAttached
    attachRendererIfNeeded()
    if !wasAttached, isRendererAttached {
      trace("call_pip_renderer_prepared")
    }
  }

  private func detachRendererIfNeeded() {
    guard isRendererAttached, let remoteVideoRenderer else {
      return
    }

    session?.detachRemoteVideoRenderer(remoteVideoRenderer)
    isRendererAttached = false
  }

  private func trace(_ name: StaticString, detail: String? = nil) {
    guard let session else {
      return
    }

    let callId: String = session.activeCallId
    session.recordPictureInPictureEvent(String(describing: name), detail: detail)
    if let detail {
      CallStartupTracer.event(name, callId: callId, detail: detail)
    } else {
      CallStartupTracer.event(name, callId: callId)
    }
  }

  private func diagnosticContext(
    source: String,
    controller: AVPictureInPictureController?,
    isActive: Bool,
    isPossible: Bool
  ) -> String {
    let controllerSummary: String
    if let controller {
      controllerSummary = [
        "possible=\(isPossible)",
        "active=\(isActive)",
        "auto=\(controller.canStartPictureInPictureAutomaticallyFromInline)",
      ].joined(separator: ",")
    } else {
      controllerSummary = "controller=nil,possible=\(isPossible),active=\(isActive),auto=unknown"
    }

    return compactDiagnostic([
      "source=\(source)",
      controllerSummary,
      // Keep audio/CallKit before verbose scene and layer data so the bounded
      // diagnostic record always preserves the route needed to distinguish
      // capture failures from playout failures.
      "audio=\(audioSessionDiagnosticsSummary)",
      "callkit=\(SystemCallCoordinator.shared.diagnosticsSummary())",
      "app=\(applicationStateDiagnosticsSummary)",
      "scenes=\(sceneDiagnosticsSummary)",
      "sourceView=\(sourceViewDiagnosticsSummary)",
      "content=\(contentViewDiagnosticsSummary)",
      "layer=\(sampleBufferLayerDiagnosticsSummary)",
      "entitlements=\(entitlementDiagnosticsSummary)",
    ].joined(separator: ","))
  }

  private func diagnosticContextWithAge(_ context: String, since date: Date?) -> String {
    guard let date else {
      return compactDiagnostic(context)
    }

    let elapsed: String = String(format: "%.1fs", Date().timeIntervalSince(date))
    return compactDiagnostic("\(context),age=\(elapsed)")
  }

  private func compactDiagnostic(_ value: String, maxLength: Int = 640) -> String {
    let normalized: String = value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maxLength else {
      return normalized
    }
    return String(normalized.prefix(maxLength))
  }

  private func installSampleBufferDisplay(in hostView: UIView, host: String) {
    guard let sampleBufferVideoRenderer else {
      return
    }

    let videoView: UIView = sampleBufferVideoRenderer.displayView
    guard videoView.superview !== hostView else {
      sampleBufferDisplayHost = host
      layoutSampleBufferDisplay(videoView, in: hostView)
      return
    }

    NSLayoutConstraint.deactivate(sampleBufferDisplayConstraints)
    sampleBufferDisplayConstraints.removeAll()
    videoView.removeFromSuperview()
    videoView.translatesAutoresizingMaskIntoConstraints = true
    videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    videoView.frame = hostView.bounds
    videoView.isHidden = false
    videoView.alpha = 1.0
    videoView.backgroundColor = .black
    videoView.clipsToBounds = true
    hostView.autoresizesSubviews = true
    hostView.clipsToBounds = true
    hostView.addSubview(videoView)
    layoutSampleBufferDisplay(videoView, in: hostView)
    sampleBufferDisplayHost = host
  }

  private func layoutSampleBufferDisplay(_ videoView: UIView, in hostView: UIView) {
    hostView.setNeedsLayout()
    hostView.layoutIfNeeded()
    videoView.frame = hostView.bounds
    videoView.bounds = CGRect(origin: .zero, size: hostView.bounds.size)
    videoView.setNeedsLayout()
    videoView.layoutIfNeeded()
  }

  private func activeVideoCallSourceView(preferredSourceView: UIView) -> UIView {
    preferredSourceView
  }

  private func isReadyVideoCallSourceView(_ sourceView: UIView) -> Bool {
    sourceView.window != nil
      && !sourceView.isHidden
      && sourceView.alpha > 0.01
      && sourceView.bounds.width >= 16
      && sourceView.bounds.height >= 16
  }

  private func videoCallSourceReadinessDiagnostics(_ sourceView: UIView) -> String {
    [
      "window=\(sourceView.window != nil)",
      "hidden=\(sourceView.isHidden)",
      "alpha=\(String(format: "%.2f", sourceView.alpha))",
      "bounds=\(Int(sourceView.bounds.width))x\(Int(sourceView.bounds.height))",
      "scene=\(sourceView.window?.windowScene?.activationState.diagnosticsName ?? "none")",
    ].joined(separator: ",")
  }

  private func preferredContentSize(for sourceView: UIView) -> CGSize {
    _ = sourceView
    return preferredVideoCallContentSize
  }

  private func placeholderFrameSize(for preferredSize: CGSize) -> CGSize {
    guard preferredSize.width > 0, preferredSize.height > 0 else {
      return CGSize(width: minimumPlaceholderShortSide, height: minimumPlaceholderShortSide)
    }

    let aspectRatio: CGFloat = preferredSize.width / preferredSize.height
    guard aspectRatio.isFinite, aspectRatio > 0 else {
      return CGSize(width: minimumPlaceholderShortSide, height: minimumPlaceholderShortSide)
    }

    if aspectRatio >= 1 {
      return CGSize(
        width: minimumPlaceholderShortSide * aspectRatio,
        height: minimumPlaceholderShortSide
      )
    }

    return CGSize(
      width: minimumPlaceholderShortSide,
      height: minimumPlaceholderShortSide / aspectRatio
    )
  }

  private var sourceViewDiagnosticsSummary: String {
    guard let sourceView else {
      return "nil"
    }

    let sceneState: String
    if let activationState = sourceView.window?.windowScene?.activationState {
      sceneState = String(describing: activationState)
    } else {
      sceneState = "no_scene"
    }

    return [
      "class=\(String(describing: type(of: sourceView)))",
      "identifier=\(sourceView.accessibilityIdentifier ?? "nil")",
      "window=\(sourceView.window != nil)",
      "windowClass=\(sourceView.window.map { String(describing: type(of: $0)) } ?? "nil")",
      "key=\(sourceView.window?.isKeyWindow == true)",
      "hidden=\(sourceView.isHidden)",
      "alpha=\(String(format: "%.2f", sourceView.alpha))",
      "bounds=\(Int(sourceView.bounds.width))x\(Int(sourceView.bounds.height))",
      "windowBounds=\(boundsDiagnostics(sourceView.window?.bounds))",
      "scene=\(sceneState)",
    ].joined(separator: ",")
  }

  private var contentViewDiagnosticsSummary: String {
    guard let contentViewController else {
      return "nil"
    }

    let view: UIView = contentViewController.view
    return [
      "preferred=\(Int(contentViewController.preferredContentSize.width))x\(Int(contentViewController.preferredContentSize.height))",
      "bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height))",
      "window=\(view.window != nil)",
      "hidden=\(view.isHidden)",
      "alpha=\(String(format: "%.2f", view.alpha))",
      "subviews=\(view.subviews.count)",
    ].joined(separator: ",")
  }

  private var sampleBufferLayerDiagnosticsSummary: String {
    guard let displayView = sampleBufferVideoRenderer?.displayView else {
      return "nil"
    }
    let displayLayer = displayView.sampleBufferDisplayLayer

    let status: String
    switch displayLayer.status {
    case .unknown:
      status = "unknown"
    case .rendering:
      status = "rendering"
    case .failed:
      status = "failed"
    @unknown default:
      status = "other"
    }

    let readyForDisplay: String
    if #available(iOS 17.4, *) {
      readyForDisplay = "\(displayLayer.isReadyForDisplay)"
    } else {
      readyForDisplay = "unavailable"
    }

    let timebaseSummary: String
    if let timebase = displayLayer.controlTimebase {
      let time = CMTimebaseGetTime(timebase)
      timebaseSummary = "rate=\(String(format: "%.2f", CMTimebaseGetRate(timebase))),time=\(String(format: "%.2f", CMTimeGetSeconds(time)))"
    } else {
      timebaseSummary = "nil"
    }

    return [
      "status=\(status)",
      "ready=\(displayLayer.isReadyForMoreMediaData)",
      "readyForDisplay=\(readyForDisplay)",
      "gravity=\(displayLayer.videoGravity.rawValue)",
      "error=\(displayLayer.error?.localizedDescription ?? "none")",
      "viewBounds=\(Int(displayView.bounds.width))x\(Int(displayView.bounds.height))",
      "bounds=\(Int(displayLayer.bounds.width))x\(Int(displayLayer.bounds.height))",
      "hidden=\(displayLayer.isHidden)",
      "opacity=\(String(format: "%.2f", displayLayer.opacity))",
      "superlayer=\(displayLayer.superlayer != nil)",
      "needsFlush=\(displayLayer.requiresFlushToResumeDecoding)",
      "timebase=\(timebaseSummary)",
    ].joined(separator: ",")
  }

  private var runtimeDiagnosticsSummary: String {
    [
      "audio=\(audioSessionDiagnosticsSummary)",
      "app=\(applicationStateDiagnosticsSummary)",
      "scenes=\(sceneDiagnosticsSummary)",
      "entitlements=\(entitlementDiagnosticsSummary)",
    ].joined(separator: ",")
  }

  private var applicationStateDiagnosticsSummary: String {
    let applicationState: String
    switch UIApplication.shared.applicationState {
    case .active:
      applicationState = "active"
    case .inactive:
      applicationState = "inactive"
    case .background:
      applicationState = "background"
    @unknown default:
      applicationState = "unknown"
    }

    let refreshStatus: String
    switch UIApplication.shared.backgroundRefreshStatus {
    case .available:
      refreshStatus = "available"
    case .denied:
      refreshStatus = "denied"
    case .restricted:
      refreshStatus = "restricted"
    @unknown default:
      refreshStatus = "unknown"
    }

    return "state=\(applicationState),backgroundRefresh=\(refreshStatus),lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled),thermal=\(thermalStateDiagnosticsSummary)"
  }

  private var sceneDiagnosticsSummary: String {
    let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard !scenes.isEmpty else {
      return "none"
    }

    return scenes.prefix(3).map { scene in
      let visibleWindows: Int = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }.count
      let keyWindow: Bool = scene.windows.contains(where: \.isKeyWindow)
      return [
        scene.activationState.diagnosticsName,
        "key=\(keyWindow)",
        "windows=\(scene.windows.count)",
        "visible=\(visibleWindows)",
        "windowDetails=\(windowDiagnosticsSummary(scene.windows))",
      ].joined(separator: ",")
    }.joined(separator: "|")
  }

  private func windowDiagnosticsSummary(_ windows: [UIWindow]) -> String {
    guard !windows.isEmpty else {
      return "none"
    }

    return windows.prefix(4).enumerated().map { index, window in
      [
        "\(index):\(String(describing: type(of: window)))",
        "key:\(window.isKeyWindow)",
        "hidden:\(window.isHidden)",
        "alpha:\(String(format: "%.2f", window.alpha))",
        "level:\(String(format: "%.1f", window.windowLevel.rawValue))",
        "root:\(window.rootViewController.map { String(describing: type(of: $0)) } ?? "nil")",
        "bounds:\(boundsDiagnostics(window.bounds))",
      ].joined(separator: ";")
    }.joined(separator: "~")
  }

  private var audioSessionDiagnosticsSummary: String {
    let session: AVAudioSession = AVAudioSession.sharedInstance()
    let outputs: String = session.currentRoute.outputs
      .map { $0.portType.rawValue }
      .joined(separator: "+")
    let inputs: String = session.currentRoute.inputs
      .map { $0.portType.rawValue }
      .joined(separator: "+")
    return [
      "category=\(session.category.rawValue)",
      "mode=\(session.mode.rawValue)",
      "options=\(session.categoryOptions.rawValue)",
      "inputAvailable=\(session.isInputAvailable)",
      "inputs=\(inputs.isEmpty ? "none" : inputs)",
      "outputs=\(outputs.isEmpty ? "none" : outputs)",
      "otherAudio=\(session.isOtherAudioPlaying)",
      "secondarySilenced=\(session.secondaryAudioShouldBeSilencedHint)",
    ].joined(separator: ",")
  }

  private var entitlementDiagnosticsSummary: String {
    let backgroundModes: String = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?
      .sorted()
      .joined(separator: "+") ?? "none"
    return "backgroundModes=\(backgroundModes),runtimeEntitlements=unavailable"
  }

  private var thermalStateDiagnosticsSummary: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown"
    }
  }

  private func boundsDiagnostics(_ bounds: CGRect?) -> String {
    guard let bounds else {
      return "nil"
    }
    return "\(Int(bounds.width))x\(Int(bounds.height))"
  }
}

private extension UIScene.ActivationState {
  var diagnosticsName: String {
    switch self {
    case .unattached:
      return "unattached"
    case .foregroundActive:
      return "foregroundActive"
    case .foregroundInactive:
      return "foregroundInactive"
    case .background:
      return "background"
    @unknown default:
      return "unknown"
    }
  }
}

extension E2ECallPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    trace("call_pip_sample_buffer_set_playing", detail: "playing=\(playing)")
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    _ = pictureInPictureController
    return CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    _ = pictureInPictureController
    return false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    trace(
      "call_pip_sample_buffer_render_size",
      detail: "width=\(newRenderSize.width),height=\(newRenderSize.height),active=\(pictureInPictureController.isPictureInPictureActive)"
    )
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    _ = pictureInPictureController
    trace("call_pip_sample_buffer_skip", detail: "seconds=\(String(format: "%.2f", CMTimeGetSeconds(skipInterval)))")
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    _ = pictureInPictureController
    return false
  }
}

extension E2ECallPictureInPictureController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    trace(
      "call_pip_will_start",
      detail: diagnosticContext(
        source: "delegate_will_start",
        controller: pictureInPictureController,
        isActive: pictureInPictureController.isPictureInPictureActive,
        isPossible: pictureInPictureController.isPictureInPicturePossible
      )
    )
    attachRendererIfNeeded()
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    _ = pictureInPictureController
    cancelStartRequestWatchdog()
    cancelAutomaticStartWatchdog()
    delayedStartWorkItem?.cancel()
    delayedStartWorkItem = nil
    attachRendererIfNeeded()
    hasDeferredStartRequest = false
    hasStartRequestInFlight = false
    timedOutStartRequestCount = 0
    lastInferredBlocker = "none"
    trace(
      "call_pip_did_start",
      detail: diagnosticContext(
        source: "delegate_did_start",
        controller: pictureInPictureController,
        isActive: pictureInPictureController.isPictureInPictureActive,
        isPossible: pictureInPictureController.isPictureInPicturePossible
      )
    )
    session?.notifyPictureInPictureDidStart()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    lastFailureDiagnosticContext = diagnosticContext(
      source: "delegate_failed,error=\(diagnosticDescription(for: error))",
      controller: pictureInPictureController,
      isActive: pictureInPictureController.isPictureInPictureActive,
      isPossible: pictureInPictureController.isPictureInPicturePossible
    )
    lastInferredBlocker = "avkit_delegate_failed"
    trace("call_pip_start_failed", detail: lastFailureDiagnosticContext)
    cancelStartRequestWatchdog()
    cancelAutomaticStartWatchdog()
    hasStartRequestInFlight = false
    hasDeferredStartRequest = false
    timedOutStartRequestCount = 0
    delayedStartWorkItem?.cancel()
    delayedStartWorkItem = nil
    prepareRendererForPictureInPicture()
    session?.notifyPictureInPictureStartFailed()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    _ = pictureInPictureController
    cancelStartRequestWatchdog()
    cancelAutomaticStartWatchdog()
    hasStartRequestInFlight = false
    hasDeferredStartRequest = false
    timedOutStartRequestCount = 0
    delayedStartWorkItem?.cancel()
    delayedStartWorkItem = nil
    trace(
      "call_pip_did_stop",
      detail: diagnosticContext(
        source: "delegate_did_stop",
        controller: pictureInPictureController,
        isActive: pictureInPictureController.isPictureInPictureActive,
        isPossible: pictureInPictureController.isPictureInPicturePossible
      )
    )
    session?.notifyPictureInPictureDidStop()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    _ = pictureInPictureController
    guard let callId: String = session?.activeCallId else {
      completionHandler(false)
      return
    }
    trace(
      "call_pip_restore_requested",
      detail: diagnosticContext(
        source: "delegate_restore",
        controller: pictureInPictureController,
        isActive: pictureInPictureController.isPictureInPictureActive,
        isPossible: pictureInPictureController.isPictureInPicturePossible
      )
    )

    NotificationCenter.default.post(
      name: .didRequestActiveCallInterfaceRestore,
      object: nil,
      userInfo: [
        "call_id": callId,
        "completion": completionHandler,
      ]
    )
  }

  private func diagnosticDescription(for error: Error) -> String {
    let nsError = error as NSError
    let base: String = "domain=\(nsError.domain),code=\(nsError.code)"
    if let localizedError = error as? LocalizedError,
      let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      return compactDiagnostic("\(base),description=\(description)", maxLength: 220)
    }

    return compactDiagnostic("\(base),description=\(String(describing: error))", maxLength: 220)
  }
}
