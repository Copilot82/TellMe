import UIKit

@MainActor
protocol ImportPrivateKeyViewControllerDelegate: AnyObject {
  func importPrivateKeyViewControllerDidFinish(_ viewController: ImportPrivateKeyViewController)
}

@MainActor
final class ImportPrivateKeyViewController: UIViewController {
  weak var delegate: ImportPrivateKeyViewControllerDelegate?

  private let viewModel: AuthViewModel
  private let userId: String

  private let textView: UITextView = UITextView()
  private let errorLabel: UILabel = UILabel()
  private let importButton: UIButton = TelegramStyle.makePrimaryButton(title: "Импортировать seed")

  init(viewModel: AuthViewModel, userId: String) {
    self.viewModel = viewModel
    self.userId = userId
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Импорт recovery phrase"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)

    configureUI()
  }

  private func configureUI() {
    TelegramStyle.styleMonospaceTextView(textView)
    textView.text = ""
    textView.heightAnchor.constraint(equalToConstant: 220).isActive = true

    errorLabel.textColor = TelegramStyle.warningColor
    errorLabel.numberOfLines = 0
    errorLabel.font = .systemFont(ofSize: 13)

    importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

    let descriptionLabel: UILabel = UILabel()
    descriptionLabel.text = "Для E2E чатов требуется recovery phrase (seed). Вставьте seed phrase и продолжите."
    descriptionLabel.numberOfLines = 0
    descriptionLabel.font = .systemFont(ofSize: 15)
    descriptionLabel.textColor = TelegramStyle.textSecondaryColor

    let stack: UIStackView = UIStackView(arrangedSubviews: [descriptionLabel, textView, errorLabel, importButton])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let containerView: UIView = UIView()
    containerView.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(containerView)
    containerView.addSubview(stack)
    view.addSubview(containerView)

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      containerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

      stack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -12),
    ])
  }

  @objc
  private func importTapped() {
    let text: String = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      errorLabel.text = "Вставьте seed phrase"
      return
    }

    do {
      try viewModel.importPrivateKey(text, for: userId)
      delegate?.importPrivateKeyViewControllerDidFinish(self)
    } catch {
      errorLabel.text = "Невалидная seed phrase"
    }
  }
}
