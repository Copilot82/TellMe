import UIKit

@MainActor
final class DiagnosticsViewController: UIViewController {
  private let viewModel: SettingsViewModel

  private let textView: UITextView = UITextView()
  private var timer: Timer?

  init(viewModel: SettingsViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Диагностика"
    let copyButton = UIBarButtonItem(title: "Скопировать", style: .plain, target: self, action: #selector(copyDiagnosticsTapped))
    copyButton.accessibilityIdentifier = MessengerAccessibility.Button.diagnosticsCopy
    navigationItem.rightBarButtonItem = copyButton

    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.diagnostics

    TelegramStyle.styleMonospaceTextView(textView)
    textView.isEditable = false
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.accessibilityIdentifier = MessengerAccessibility.View.diagnosticsOutput

    let containerView: UIView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(containerView)
    containerView.addSubview(textView)

    view.addSubview(containerView)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      containerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      containerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

      textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
      textView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
      textView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
      textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
    ])

    render()
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.viewModel.refreshNetworkDiagnostics(force: true)
      self.render()
    }

    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { [weak self] _ in
      guard let self else {
        return
      }

      Task { @MainActor in
        await self.viewModel.refreshNetworkDiagnostics()
        self.render()
      }
    })
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    timer?.invalidate()
    timer = nil
  }

  private func render() {
    textView.text = """
    \(Date())

    \(viewModel.diagnosticsSummary())
    """
  }

  @objc
  private func copyDiagnosticsTapped() {
    UIPasteboard.general.string = textView.text
    navigationItem.rightBarButtonItem?.title = "Скопировано"
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      self?.navigationItem.rightBarButtonItem?.title = "Скопировать"
    }
  }
}
