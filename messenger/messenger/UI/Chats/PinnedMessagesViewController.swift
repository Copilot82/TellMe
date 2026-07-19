import UIKit

@MainActor
final class PinnedMessagesViewController: UIViewController {
  private let viewModel: ConversationViewModel

  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)
  private var pinnedMessages: [PinnedMessage] = []

  init(viewModel: ConversationViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Закреплённые"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "pin")
    tableView.dataSource = self
    tableView.delegate = self
    TelegramStyle.styleTableView(tableView)

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    Task {
      await reload()
    }
  }

  private func reload() async {
    do {
      pinnedMessages = try await viewModel.listPinnedMessages()
      tableView.reloadData()
    } catch {
      showErrorAlert(message: "Не удалось загрузить pinned")
    }
  }
}

extension PinnedMessagesViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    pinnedMessages.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: "pin", for: indexPath)
    let pin: PinnedMessage = pinnedMessages[indexPath.row]

    var content: UIListContentConfiguration = cell.defaultContentConfiguration()
    content.text = viewModel.pinnedMessagePreviewText(pin.messageId)
    content.secondaryText = "Закрепил: \(pin.pinnedBy.prefix(8))"
    content.textProperties.color = TelegramStyle.textPrimaryColor
    content.secondaryTextProperties.color = TelegramStyle.textSecondaryColor

    cell.contentConfiguration = content
    TelegramStyle.styleListCell(cell)
    return cell
  }
}

extension PinnedMessagesViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard viewModel.isCurrentUserAdmin else {
      return nil
    }

    let pin: PinnedMessage = pinnedMessages[indexPath.row]

    let unpin: UIContextualAction = UIContextualAction(style: .destructive, title: "Открепить") { [weak self] _, _, completion in
      guard let self else {
        completion(false)
        return
      }

      Task {
        do {
          try await self.viewModel.unpinMessage(messageId: pin.messageId)
          await self.reload()
          completion(true)
        } catch {
          self.showErrorAlert(message: "Не удалось открепить")
          completion(false)
        }
      }
    }

    return UISwipeActionsConfiguration(actions: [unpin])
  }
}
