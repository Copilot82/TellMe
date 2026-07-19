import UIKit
import WebRTC

@MainActor
// The call screen binds renderers late so media sessions can survive UI transitions.
final class E2ECallViewController: UIViewController {
  private let viewModel: E2ECallSessionViewModel
  private let shouldAutoStart: Bool

  private let remoteVideoView: RTCMTLVideoView = RTCMTLVideoView()
  private let localVideoView: RTCMTLVideoView = RTCMTLVideoView()
  private let audioAvatarView: UIView = UIView()
  private let audioAvatarLabel: UILabel = UILabel()
  private let peerLabel: UILabel = UILabel()
  private let statusLabel: UILabel = UILabel()
  private let durationLabel: UILabel = UILabel()
  private let muteButton: UIButton = UIButton(type: .system)
  private let cameraButton: UIButton = UIButton(type: .system)
  private let endButton: UIButton = UIButton(type: .system)

  private var shouldKeepCallAliveOnDisappear: Bool = true
  private var inlineVideoRenderersAttached: Bool = false
  private var isViewVisible: Bool = true
  private var isApplicationInactiveForPictureInPicture: Bool = false
  private var startedAt: Date?
  private var durationTimer: Timer?
  private var willResignActiveObserver: NSObjectProtocol?
  private var didEnterBackgroundObserver: NSObjectProtocol?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var hasRequestedSessionStart: Bool = false

  init(viewModel: E2ECallSessionViewModel, shouldAutoStart: Bool = true) {
    self.viewModel = viewModel
    self.shouldAutoStart = shouldAutoStart
    super.init(nibName: nil, bundle: nil)
  }

  var activeCallId: String {
    viewModel.activeCallId
  }

#if DEBUG
  var remoteVideoViewForTesting: UIView {
    remoteVideoView
  }

  var isInlineVideoRendererAttachedForTesting: Bool {
    inlineVideoRenderersAttached
  }

  var isDurationTimerActiveForTesting: Bool {
    durationTimer != nil
  }
#endif

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    CallStartupTracer.event("call_view_did_load", callId: viewModel.activeCallId)

    title = "Звонок"
    view.backgroundColor = .black
    view.accessibilityIdentifier = MessengerAccessibility.Screen.activeCall

    configureUI()
    configureApplicationStateObservers()
    attachInlineVideoRenderersIfNeeded()
    configurePictureInPicture()
    render()

    viewModel.onStateChanged = { [weak self] in
      self?.render()
    }
    viewModel.onFinished = { [weak self] in
      self?.handleSessionFinished()
    }
    viewModel.onPictureInPictureDidStart = { [weak self] in
      self?.handlePictureInPictureDidStart()
    }
    viewModel.onPictureInPictureStartFailed = { [weak self] in
      self?.handlePictureInPictureStartFailedOrStopped()
    }
    viewModel.onPictureInPictureDidStop = { [weak self] in
      self?.handlePictureInPictureStartFailedOrStopped()
    }
    startDurationTimer()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    attachInlineVideoRenderersIfNeeded()
    configurePictureInPicture()
    startDurationTimer()
    isViewVisible = true
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    configurePictureInPicture()
    startSessionAfterInitialRenderIfNeeded()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    configurePictureInPicture()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)

    guard shouldKeepCallAliveOnDisappear else {
      return
    }

    guard !isApplicationInactiveForPictureInPicture else {
      configurePictureInPicture()
      return
    }

    viewModel.startPictureInPictureIfPossible(reason: "screen_disappear")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)

    isViewVisible = false
    stopDurationTimer()

    guard shouldKeepCallAliveOnDisappear, viewModel.isPictureInPictureActive else {
      return
    }

    detachInlineVideoRenderersIfNeeded()
  }

  deinit {
    let notificationCenter = NotificationCenter.default
    if let willResignActiveObserver {
      notificationCenter.removeObserver(willResignActiveObserver)
    }
    if let didEnterBackgroundObserver {
      notificationCenter.removeObserver(didEnterBackgroundObserver)
    }
    if let didBecomeActiveObserver {
      notificationCenter.removeObserver(didBecomeActiveObserver)
    }
    durationTimer?.invalidate()
    durationTimer = nil
    Task { @MainActor [viewModel, localVideoView, remoteVideoView] in
      viewModel.detachVideoRenderers(local: localVideoView, remote: remoteVideoView)
    }
  }

  private func configureApplicationStateObservers() {
    let notificationCenter = NotificationCenter.default

    willResignActiveObserver = notificationCenter.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleApplicationWillResignActive()
      }
    }

    didEnterBackgroundObserver = notificationCenter.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleApplicationDidEnterBackground()
      }
    }

    didBecomeActiveObserver = notificationCenter.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleApplicationDidBecomeActive()
      }
    }
  }

  private func startSessionAfterInitialRenderIfNeeded() {
    guard shouldAutoStart, !hasRequestedSessionStart else {
      return
    }

    hasRequestedSessionStart = true
    CallStartupTracer.event("call_deferred_start_scheduled", callId: viewModel.activeCallId)
    Task { @MainActor [weak self] in
      await Task.yield()
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard let self else {
        return
      }

      CallStartupTracer.event("call_deferred_start_begin", callId: self.viewModel.activeCallId)
      self.viewModel.start()
    }
  }

  private func configureUI() {
    navigationItem.largeTitleDisplayMode = .never

    remoteVideoView.translatesAutoresizingMaskIntoConstraints = false
    remoteVideoView.videoContentMode = .scaleAspectFill
    remoteVideoView.backgroundColor = .black
    remoteVideoView.assignAccessibilityIdentifier(MessengerAccessibility.View.callRemoteVideo)
    view.addSubview(remoteVideoView)

    let dimOverlay = UIView()
    dimOverlay.translatesAutoresizingMaskIntoConstraints = false
    dimOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.22)
    view.addSubview(dimOverlay)

    audioAvatarView.translatesAutoresizingMaskIntoConstraints = false
    audioAvatarView.backgroundColor = TelegramStyle.accentColor.withAlphaComponent(0.28)
    audioAvatarView.layer.cornerRadius = 56
    audioAvatarView.layer.borderWidth = 1
    audioAvatarView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
    view.addSubview(audioAvatarView)

    audioAvatarLabel.translatesAutoresizingMaskIntoConstraints = false
    audioAvatarLabel.textAlignment = .center
    audioAvatarLabel.textColor = .white
    audioAvatarLabel.font = .systemFont(ofSize: 42, weight: .bold)
    audioAvatarView.addSubview(audioAvatarLabel)

    localVideoView.translatesAutoresizingMaskIntoConstraints = false
    localVideoView.videoContentMode = .scaleAspectFill
    localVideoView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
    localVideoView.layer.cornerRadius = 14
    localVideoView.layer.masksToBounds = true
    localVideoView.layer.borderWidth = 1
    localVideoView.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
    localVideoView.assignAccessibilityIdentifier(MessengerAccessibility.View.callLocalVideo)
    view.addSubview(localVideoView)

    peerLabel.translatesAutoresizingMaskIntoConstraints = false
    peerLabel.textAlignment = .center
    peerLabel.textColor = .white
    peerLabel.font = .systemFont(ofSize: 28, weight: .bold)
    peerLabel.adjustsFontSizeToFitWidth = true
    peerLabel.minimumScaleFactor = 0.72
    view.addSubview(peerLabel)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textAlignment = .center
    statusLabel.textColor = UIColor.white.withAlphaComponent(0.82)
    statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
    statusLabel.numberOfLines = 2
    statusLabel.accessibilityIdentifier = MessengerAccessibility.Label.callStatus
    view.addSubview(statusLabel)

    durationLabel.translatesAutoresizingMaskIntoConstraints = false
    durationLabel.textAlignment = .center
    durationLabel.textColor = UIColor.white.withAlphaComponent(0.64)
    durationLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    durationLabel.accessibilityIdentifier = MessengerAccessibility.Label.callDuration
    view.addSubview(durationLabel)

    configureControlButton(
      muteButton,
      systemName: "mic.fill",
      accessibilityIdentifier: MessengerAccessibility.Button.callMute
    )
    configureControlButton(
      cameraButton,
      systemName: "video.fill",
      accessibilityIdentifier: MessengerAccessibility.Button.callCamera
    )
    configureControlButton(
      endButton,
      systemName: "phone.down.fill",
      accessibilityIdentifier: MessengerAccessibility.Button.callEnd
    )
    endButton.backgroundColor = UIColor.systemRed

    muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
    cameraButton.addTarget(self, action: #selector(cameraTapped), for: .touchUpInside)
    endButton.addTarget(self, action: #selector(endTapped), for: .touchUpInside)

    let controlsStack = UIStackView(arrangedSubviews: [muteButton, cameraButton, endButton])
    controlsStack.translatesAutoresizingMaskIntoConstraints = false
    controlsStack.axis = .horizontal
    controlsStack.alignment = .center
    controlsStack.distribution = .equalCentering
    controlsStack.spacing = 28
    view.addSubview(controlsStack)

    NSLayoutConstraint.activate([
      remoteVideoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      remoteVideoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      remoteVideoView.topAnchor.constraint(equalTo: view.topAnchor),
      remoteVideoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      dimOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dimOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dimOverlay.topAnchor.constraint(equalTo: view.topAnchor),
      dimOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      localVideoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
      localVideoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      localVideoView.widthAnchor.constraint(equalToConstant: 112),
      localVideoView.heightAnchor.constraint(equalToConstant: 156),

      audioAvatarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      audioAvatarView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -42),
      audioAvatarView.widthAnchor.constraint(equalToConstant: 112),
      audioAvatarView.heightAnchor.constraint(equalToConstant: 112),

      audioAvatarLabel.leadingAnchor.constraint(equalTo: audioAvatarView.leadingAnchor),
      audioAvatarLabel.trailingAnchor.constraint(equalTo: audioAvatarView.trailingAnchor),
      audioAvatarLabel.topAnchor.constraint(equalTo: audioAvatarView.topAnchor),
      audioAvatarLabel.bottomAnchor.constraint(equalTo: audioAvatarView.bottomAnchor),

      peerLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      peerLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      peerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),

      statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
      statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
      statusLabel.topAnchor.constraint(equalTo: peerLabel.bottomAnchor, constant: 8),

      durationLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      durationLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),

      controlsStack.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: 28
      ),
      controlsStack.trailingAnchor.constraint(
        lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -28
      ),
      controlsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -34),

      muteButton.widthAnchor.constraint(equalToConstant: 62),
      muteButton.heightAnchor.constraint(equalToConstant: 62),
      cameraButton.widthAnchor.constraint(equalToConstant: 62),
      cameraButton.heightAnchor.constraint(equalToConstant: 62),
      endButton.widthAnchor.constraint(equalToConstant: 68),
      endButton.heightAnchor.constraint(equalToConstant: 68),
    ])
  }

  private func configureControlButton(_ button: UIButton, systemName: String, accessibilityIdentifier: String) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    button.backgroundColor = UIColor.white.withAlphaComponent(0.18)
    button.layer.cornerRadius = 31
    button.accessibilityIdentifier = accessibilityIdentifier
    button.setImage(UIImage(systemName: systemName), for: .normal)
  }

  private func attachInlineVideoRenderersIfNeeded() {
    guard !inlineVideoRenderersAttached else {
      return
    }

    viewModel.attachVideoRenderers(local: localVideoView, remote: remoteVideoView)
    inlineVideoRenderersAttached = true
  }

  private func detachInlineVideoRenderersIfNeeded() {
    guard inlineVideoRenderersAttached else {
      return
    }

    viewModel.detachVideoRenderers(local: localVideoView, remote: remoteVideoView)
    inlineVideoRenderersAttached = false
  }

  private func handlePictureInPictureDidStart() {
    guard shouldKeepCallAliveOnDisappear,
      !isViewVisible || isApplicationInactiveForPictureInPicture
    else {
      return
    }

    detachInlineVideoRenderersIfNeeded()
  }

  private func handlePictureInPictureStartFailedOrStopped() {
    guard shouldKeepCallAliveOnDisappear,
      !isViewVisible || isApplicationInactiveForPictureInPicture
    else {
      return
    }

    attachInlineVideoRenderersIfNeeded()
  }

  // App backgrounding is treated as a PiP transition candidate before the controller releases media renderers.
  private func handleApplicationWillResignActive() {
    guard shouldKeepCallAliveOnDisappear, isViewVisible else {
      return
    }

    isApplicationInactiveForPictureInPicture = true
    viewModel.preparePictureInPictureForAutomaticStart(sourceView: pictureInPictureSourceView, reason: "will_resign_active")
  }

  private func handleApplicationDidEnterBackground() {
    guard shouldKeepCallAliveOnDisappear, isApplicationInactiveForPictureInPicture else {
      return
    }

    viewModel.preparePictureInPictureForAutomaticStart(sourceView: pictureInPictureSourceView, reason: "did_enter_background")
  }

  private func handleApplicationDidBecomeActive() {
    isApplicationInactiveForPictureInPicture = false
    guard isViewVisible else {
      return
    }

    attachInlineVideoRenderersIfNeeded()
    configurePictureInPicture()
    startDurationTimer()
  }

  private var pictureInPictureSourceView: UIView {
    view
  }

  private func configurePictureInPicture() {
    viewModel.configurePictureInPicture(sourceView: pictureInPictureSourceView)
  }

  private func render() {
#if DEBUG
    let incomingDiagnostics: String = SystemCallCoordinator.shared.incomingDeliveryDiagnosticsForTesting(
      callId: viewModel.activeCallId
    )
    view.accessibilityValue = "callId=\(viewModel.activeCallId) pip=\(viewModel.pictureInPictureDiagnosticsSummary) incoming=\(incomingDiagnostics)"
#else
    view.accessibilityValue = "callId=\(viewModel.activeCallId) pip=\(viewModel.pictureInPictureDiagnosticsSummary)"
#endif
    peerLabel.text = viewModel.title
    statusLabel.text = viewModel.statusText
    audioAvatarLabel.text = String(viewModel.title.prefix(1)).uppercased()
    cameraButton.isHidden = !viewModel.showsCameraControl
    remoteVideoView.isHidden = !viewModel.showsCameraControl
    localVideoView.isHidden = !viewModel.showsCameraControl || !viewModel.isCameraEnabled
    audioAvatarView.isHidden = viewModel.showsCameraControl

    let mutedSymbol: String = viewModel.isMuted ? "mic.slash.fill" : "mic.fill"
    muteButton.setImage(UIImage(systemName: mutedSymbol), for: .normal)
    muteButton.backgroundColor = viewModel.isMuted ? UIColor.systemOrange : UIColor.white.withAlphaComponent(0.18)

    let cameraSymbol: String = viewModel.isCameraEnabled ? "video.fill" : "video.slash.fill"
    cameraButton.setImage(UIImage(systemName: cameraSymbol), for: .normal)
    cameraButton.backgroundColor = viewModel.isCameraEnabled
      ? UIColor.white.withAlphaComponent(0.18)
      : UIColor.systemOrange

    switch viewModel.state {
    case .connected:
      if startedAt == nil {
        startedAt = Date()
      }
      endButton.isEnabled = true
      updateDuration()
    case .ended:
      endButton.isEnabled = false
      durationLabel.text = "Завершено"
    case .failed:
      endButton.isEnabled = true
      durationLabel.text = "Ошибка"
    default:
      endButton.isEnabled = true
      if startedAt == nil {
        durationLabel.text = "00:00"
      }
    }
  }

  private func startDurationTimer() {
    guard durationTimer == nil else {
      return
    }

    durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.updateDuration()
      }
    }
  }

  private func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
  }

  private func updateDuration() {
    guard let startedAt else {
      durationLabel.text = "00:00"
      return
    }

    let elapsed: Int = max(0, Int(Date().timeIntervalSince(startedAt)))
    durationLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
  }

  private func handleSessionFinished() {
    guard case .ended = viewModel.state else {
      return
    }

    shouldKeepCallAliveOnDisappear = false
    stopDurationTimer()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
      guard let self,
        self.navigationController?.topViewController === self
      else {
        return
      }

      self.navigationController?.popViewController(animated: true)
    }
  }

  @objc
  private func muteTapped() {
    viewModel.setMuted(!viewModel.isMuted)
  }

  @objc
  private func cameraTapped() {
    viewModel.setCameraEnabled(!viewModel.isCameraEnabled)
  }

  @objc
  private func endTapped() {
    Task {
      shouldKeepCallAliveOnDisappear = false
      await viewModel.endFromUser()
      navigationController?.popViewController(animated: true)
    }
  }
}
