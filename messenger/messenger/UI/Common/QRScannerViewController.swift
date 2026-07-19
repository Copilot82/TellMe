@preconcurrency import AVFoundation
import UIKit

private final class QRScannerSessionController: @unchecked Sendable {
  let captureSession: AVCaptureSession = AVCaptureSession()

  private let sessionQueue: DispatchQueue = DispatchQueue(label: "messenger.qrscanner.session")
  private var didConfigureSession: Bool = false

  func configureIfNeeded(metadataDelegate: AVCaptureMetadataOutputObjectsDelegate) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: ())
          return
        }

        do {
          guard !self.didConfigureSession else {
            continuation.resume(returning: ())
            return
          }

          guard let device: AVCaptureDevice = AVCaptureDevice.default(for: .video) else {
            throw APIError.transport("Camera unavailable")
          }

          let input: AVCaptureDeviceInput = try AVCaptureDeviceInput(device: device)
          if self.captureSession.canAddInput(input) {
            self.captureSession.addInput(input)
          }

          let metadataOutput: AVCaptureMetadataOutput = AVCaptureMetadataOutput()
          if self.captureSession.canAddOutput(metadataOutput) {
            self.captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(metadataDelegate, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
          }

          self.didConfigureSession = true
          continuation.resume(returning: ())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func startRunning() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: ())
          return
        }

        if !self.captureSession.isRunning {
          self.captureSession.startRunning()
        }

        continuation.resume(returning: ())
      }
    }
  }

  func stopRunning() {
    sessionQueue.async { [weak self] in
      guard let self, self.captureSession.isRunning else {
        return
      }

      self.captureSession.stopRunning()
    }
  }
}

@MainActor
final class QRScannerViewController: UIViewController {
  var onCodeScanned: ((String) -> Void)?

  private let sessionController: QRScannerSessionController = QRScannerSessionController()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let previewContainer: UIView = UIView()
  private let errorLabel: UILabel = UILabel()
  private var didHandleScan: Bool = false

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Скан QR"
    view.backgroundColor = .black
    view.accessibilityIdentifier = MessengerAccessibility.Screen.qrScanner
    configureLayout()

    Task {
      await configureScannerIfAuthorized()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    sessionController.stopRunning()
  }

  private func configureLayout() {
    previewContainer.translatesAutoresizingMaskIntoConstraints = false
    previewContainer.backgroundColor = .black
    previewContainer.accessibilityIdentifier = MessengerAccessibility.View.qrScannerPreview
    view.addSubview(previewContainer)

    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.textColor = .white
    errorLabel.font = .systemFont(ofSize: 14, weight: .medium)
    errorLabel.numberOfLines = 0
    errorLabel.textAlignment = .center
    errorLabel.accessibilityIdentifier = MessengerAccessibility.Label.qrScannerError
    view.addSubview(errorLabel)

    NSLayoutConstraint.activate([
      previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
      previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      errorLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      errorLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      errorLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])
  }

  private func configureScannerIfAuthorized() async {
    let status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .notDetermined {
      _ = await AVCaptureDevice.requestAccess(for: .video)
    }

    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      presentError("Доступ к камере не выдан")
      return
    }

    let previewLayer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: sessionController.captureSession)
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.frame = previewContainer.layer.bounds

    previewContainer.layer.insertSublayer(previewLayer, at: 0)
    self.previewLayer = previewLayer

    do {
      try await sessionController.configureIfNeeded(metadataDelegate: self)
      try await sessionController.startRunning()
    } catch {
      presentError("Не удалось запустить камеру")
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = previewContainer.bounds
  }

  private func presentError(_ message: String) {
    errorLabel.text = message
    showErrorAlert(message: message)
  }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    _ = output
    _ = connection

    guard let object: AVMetadataMachineReadableCodeObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      object.type == .qr,
      let value: String = object.stringValue
    else {
      return
    }

    guard !didHandleScan else {
      return
    }

    didHandleScan = true
    sessionController.stopRunning()
    onCodeScanned?(value)
    navigationController?.popViewController(animated: true)
  }
}
