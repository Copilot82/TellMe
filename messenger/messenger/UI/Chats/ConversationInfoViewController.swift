import UIKit

@MainActor
final class ConversationInfoViewController: UIViewController {
  var onConversationUpdated: ((Conversation) -> Void)?
  var onOpenPinnedMessages: (() -> Void)?

  private let container: AppContainer
  private var conversation: Conversation

  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)

  private var currentUserId: String? {
    container.sessionStore.currentUser?.id
  }

  private var isCurrentUserAdmin: Bool {
    guard let currentUserId: String = currentUserId,
      let participants: [ConversationParticipant] = conversation.participants
    else {
      return false
    }

    return participants.first(where: { $0.userId == currentUserId })?.role == .admin
  }

  private var adminCount: Int {
    conversation.participants?.filter({ $0.role == .admin }).count ?? 0
  }

  init(container: AppContainer, conversation: Conversation) {
    self.container = container
    self.conversation = conversation
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    title = "Информация"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)

    configureTable()

    Task {
      await reloadConversation()
    }
  }

  private func configureTable() {
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Закрепы", style: .plain, target: self, action: #selector(openPinned))

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "participant")
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
  }

  private func reloadConversation() async {
    onConversationUpdated?(conversation)
    tableView.reloadData()
  }

  @objc
  private func openPinned() {
    onOpenPinnedMessages?()
  }

  private func promptAddParticipant() {
    showErrorAlert(message: "Управление участниками недоступно после hard-cutover.")
  }

  private func updateRole(userId: String, role: ConversationParticipant.Role) {
    _ = userId
    _ = role
    showErrorAlert(message: "Управление ролями недоступно после hard-cutover.")
  }

  private func removeParticipant(userId: String) {
    _ = userId
    showErrorAlert(message: "Удаление участников недоступно после hard-cutover.")
  }

  private func leaveOrDeleteConversation() {
    showErrorAlert(message: "Удаление чата из этого экрана недоступно в текущем релизе.")
  }
}

extension ConversationInfoViewController: UITableViewDataSource {
  func numberOfSections(in tableView: UITableView) -> Int {
    2
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if section == 0 {
      return conversation.participants?.count ?? 0
    }

    return 2
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == 0 ? "Участники" : "Управление"
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: "participant", for: indexPath)
    var content: UIListContentConfiguration = cell.defaultContentConfiguration()

    if indexPath.section == 0 {
      let participant: ConversationParticipant = conversation.participants?[indexPath.row] ?? ConversationParticipant(
        id: "",
        conversationId: conversation.id,
        userId: "",
        joinedAt: nil,
        role: .member
      )

      content.text = participant.userId
      content.secondaryText = participant.role.rawValue
      content.textProperties.color = TelegramStyle.textPrimaryColor
      content.secondaryTextProperties.color = TelegramStyle.textSecondaryColor
      cell.accessoryType = .disclosureIndicator
      cell.contentConfiguration = content
      TelegramStyle.styleListCell(cell)
      return cell
    }

    if indexPath.row == 0 {
      content.text = "Добавить участника"
      content.textProperties.color = TelegramStyle.accentColor
    } else {
      content.text = "Выйти / удалить диалог"
      content.textProperties.color = TelegramStyle.destructiveColor
    }

    cell.accessoryType = .none
    cell.contentConfiguration = content
    TelegramStyle.styleListCell(cell)
    return cell
  }
}

extension ConversationInfoViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)

    if indexPath.section == 1 {
      if indexPath.row == 0 {
        promptAddParticipant()
      } else {
        leaveOrDeleteConversation()
      }
      return
    }

    guard let participant: ConversationParticipant = conversation.participants?[indexPath.row] else {
      return
    }

    guard isCurrentUserAdmin else {
      showErrorAlert(message: "Только admin может управлять ролями и участниками")
      return
    }

    let sheet: UIAlertController = UIAlertController(title: participant.userId, message: nil, preferredStyle: .actionSheet)

    sheet.addAction(UIAlertAction(title: "Сделать admin", style: .default, handler: { [weak self] _ in
      self?.updateRole(userId: participant.userId, role: .admin)
    }))

    sheet.addAction(UIAlertAction(title: "Сделать member", style: .default, handler: { [weak self] _ in
      self?.updateRole(userId: participant.userId, role: .member)
    }))

    sheet.addAction(UIAlertAction(title: "Удалить участника", style: .destructive, handler: { [weak self] _ in
      self?.removeParticipant(userId: participant.userId)
    }))

    sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))

    if let popover: UIPopoverPresentationController = sheet.popoverPresentationController,
      let cell: UITableViewCell = tableView.cellForRow(at: indexPath)
    {
      popover.sourceView = cell
      popover.sourceRect = cell.bounds
    }

    present(sheet, animated: true)
  }
}
