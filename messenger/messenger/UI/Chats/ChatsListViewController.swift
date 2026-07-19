import UIKit

@MainActor
final class ChatsListViewController: UIViewController {
  var onOpenConversation: ((Conversation) -> Void)?
  var onCreateConversation: (() -> Void)?
  var onShowMyCode: (() -> Void)?

  private let viewModel: ChatsViewModel

  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)
  private let refreshControl: UIRefreshControl = UIRefreshControl()
  private let newChatButton: UIButton = TelegramStyle.makeFloatingActionButton(symbolName: "square.and.pencil")

  init(viewModel: ChatsViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Чаты"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.chats

    configureTable()
    configureSearch()
    configureFloatingButton()
    configureNavigationActions()
    viewModel.onStateChanged = { [weak self] in
      self?.tableView.reloadData()
    }

    Task {
      await reloadConversations()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    Task {
      await reloadConversations()
    }
  }

  private func configureTable() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "chat")
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = 68
    TelegramStyle.styleTableView(tableView)

    refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
    tableView.refreshControl = refreshControl

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func configureSearch() {
    let searchController: UISearchController = UISearchController(searchResultsController: nil)
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = "Поиск чатов"
    searchController.searchBar.searchTextField.accessibilityIdentifier = MessengerAccessibility.Input.chatsSearch
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = false
  }

  private func configureFloatingButton() {
    newChatButton.translatesAutoresizingMaskIntoConstraints = false
    newChatButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
    newChatButton.accessibilityIdentifier = MessengerAccessibility.Button.chatsNew
    newChatButton.accessibilityLabel = "Новый чат"
    view.addSubview(newChatButton)

    NSLayoutConstraint.activate([
      newChatButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      newChatButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -18),
    ])
  }

  private func configureNavigationActions() {
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Мой код",
      style: .plain,
      target: self,
      action: #selector(showMyCodeTapped)
    )
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = MessengerAccessibility.Button.chatsMyCode
  }

  @objc
  private func addTapped() {
    onCreateConversation?()
  }

  @objc
  private func showMyCodeTapped() {
    onShowMyCode?()
  }

  @objc
  private func refreshPulled() {
    Task {
      await reloadConversations()
      refreshControl.endRefreshing()
    }
  }

  private func reloadConversations() async {
    do {
      try await viewModel.loadConversations()
      tableView.reloadData()
    } catch {
      if viewModel.filteredConversations.isEmpty {
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  private func confirmDeleteConversation(_ conversation: Conversation) {
    let title: String = viewModel.title(for: conversation, currentUserId: viewModel.currentUserId)
    let alert: UIAlertController = UIAlertController(
      title: "Удалить диалог",
      message: "Удалить диалог с \(title)?",
      preferredStyle: .alert
    )

    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: "Удалить", style: .destructive, handler: { [weak self] _ in
      guard let self else {
        return
      }

      do {
        try self.viewModel.deleteConversation(id: conversation.id)
      } catch {
        self.showErrorAlert(message: error.localizedDescription)
      }
    }))

    present(alert, animated: true)
  }

  private func confirmBlockConversation(_ conversation: Conversation) {
    let title: String = viewModel.title(for: conversation, currentUserId: viewModel.currentUserId)
    let alert: UIAlertController = UIAlertController(
      title: "Заблокировать пользователя",
      message: "Заблокировать \(title) и удалить диалог на этом устройстве?",
      preferredStyle: .alert
    )

    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: "Заблокировать", style: .destructive, handler: { [weak self] _ in
      guard let self else {
        return
      }

      Task {
        do {
          try await self.viewModel.blockPeer(in: conversation)
          try self.viewModel.deleteConversation(id: conversation.id)
        } catch {
          self.showErrorAlert(message: error.localizedDescription)
        }
      }
    }))

    present(alert, animated: true)
  }
}

extension ChatsListViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    viewModel.filteredConversations.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: "chat", for: indexPath)
    var content: UIListContentConfiguration = cell.defaultContentConfiguration()

    let conversation: Conversation = viewModel.filteredConversations[indexPath.row]
    content.text = viewModel.title(for: conversation, currentUserId: viewModel.currentUserId)
    let typeText: String = conversation.type == .group ? "Группа" : "Личный чат"
    content.secondaryText = "\(typeText) • \(conversation.id.prefix(8))"
    content.textProperties.color = TelegramStyle.textPrimaryColor
    content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    content.secondaryTextProperties.color = TelegramStyle.textSecondaryColor
    content.image = UIImage(systemName: conversation.type == .group ? "person.3.fill" : "person.fill")
    content.imageProperties.tintColor = TelegramStyle.accentColor

    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = MessengerAccessibility.View.chatCell(conversation.id)
    TelegramStyle.styleListCell(cell)

    return cell
  }
}

extension ChatsListViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let conversation: Conversation = viewModel.filteredConversations[indexPath.row]
    onOpenConversation?(conversation)
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let conversation: Conversation = viewModel.filteredConversations[indexPath.row]

    let deleteAction = UIContextualAction(style: .destructive, title: "Удалить") { [weak self] _, _, completion in
      self?.confirmDeleteConversation(conversation)
      completion(true)
    }

    if conversation.type != .direct || viewModel.peerUserHandle(for: conversation) == nil {
      return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    let blockAction = UIContextualAction(style: .normal, title: "Блок") { [weak self] _, _, completion in
      self?.confirmBlockConversation(conversation)
      completion(true)
    }
    blockAction.backgroundColor = TelegramStyle.warningColor

    let configuration: UISwipeActionsConfiguration = UISwipeActionsConfiguration(actions: [deleteAction, blockAction])
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }
}

extension ChatsListViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    viewModel.applySearch(searchController.searchBar.text ?? "")
    tableView.reloadData()
  }
}
