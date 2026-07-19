import UIKit

extension UIViewController {
  func showErrorAlert(message: String, title: String = "Ошибка") {
    let alert: UIAlertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  func showInputAlert(
    title: String,
    message: String? = nil,
    placeholder: String,
    actionTitle: String = "OK",
    keyboardType: UIKeyboardType = .default,
    completion: @escaping (String) -> Void
  ) {
    let alert: UIAlertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.placeholder = placeholder
      textField.keyboardType = keyboardType
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
    }

    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in
      let value: String = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !value.isEmpty else {
        return
      }
      completion(value)
    })

    present(alert, animated: true)
  }

  func installAlertAccessibilityIdentifiers(
    on alert: UIAlertController,
    alertIdentifier: String,
    buttonIdentifiersByTitle: [String: String]
  ) {
    alert.view.accessibilityIdentifier = alertIdentifier
    alert.view.isAccessibilityElement = false

    guard !buttonIdentifiersByTitle.isEmpty else {
      return
    }

    DispatchQueue.main.async {
      self.assignButtonAccessibilityIdentifiers(in: alert.view, identifiersByTitle: buttonIdentifiersByTitle)
    }
  }

  private func assignButtonAccessibilityIdentifiers(in root: UIView, identifiersByTitle: [String: String]) {
    if let button: UIButton = root as? UIButton,
      let title: String = button.currentTitle ?? button.titleLabel?.text,
      let identifier: String = identifiersByTitle[title]
    {
      button.accessibilityIdentifier = identifier
    }

    for child in root.subviews {
      assignButtonAccessibilityIdentifiers(in: child, identifiersByTitle: identifiersByTitle)
    }
  }
}
