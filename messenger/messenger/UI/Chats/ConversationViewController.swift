import CryptoKit
import OSLog
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
// This controller owns presentation state; message ordering and encryption decisions stay in the view model.
final class ConversationViewController: UIViewController {
  private enum AttachmentOperation: Equatable {
    case preview(messageId: String)
    case export(messageId: String)

    var loadingText: String {
      switch self {
      case .preview:
        return "Открытие вложения…"
      case .export:
        return "Подготовка экспорта…"
      }
    }
  }

  struct MessageViewData {
    let id: String
    let text: String
    let replyPreview: String?
    let isForwarded: Bool
    let forwardedText: String?
    let reactionsSummary: String?
    let footer: String
    let showEdited: Bool
    let isOutgoing: Bool
    let isDeleted: Bool
  }

  private let viewModel: ConversationViewModel

  var onStartCall: ((ConversationViewModel, Call.CallType) -> Void)?
  var onAnswerCall: ((ConversationViewModel, CallSessionDescriptionSignal, Call.CallType, String) -> Void)?

  private let tableView: UITableView = UITableView(frame: .zero, style: .plain)
  private let securityBannerView: UIView = UIView()
  private let securityBannerLabel: UILabel = UILabel()
  private let verifyKeyButton: UIButton = UIButton(type: .system)
  private let pinnedBannerContainer: UIView = UIView()
  private let typingLabel: UILabel = UILabel()
  private let composerContainer: UIView = UIView()
  private let scrollToBottomContainer: UIView = UIView()
  private let replyPreviewContainer: UIView = UIView()
  private let replyPreviewLabel: UILabel = UILabel()
  private let clearReplyButton: UIButton = UIButton(type: .system)
  private let inputField: UITextField = TelegramStyle.makeTextField(placeholder: "Сообщение")
  private let sendButton: UIButton = UIButton(type: .system)
  private let attachButton: UIButton = UIButton(type: .system)
  private let attachmentLoadingContainer: UIView = UIView()
  private let attachmentLoadingIndicator: UIActivityIndicatorView = UIActivityIndicatorView(style: .medium)
  private let attachmentLoadingLabel: UILabel = UILabel()

  private var selectedReplyMessageId: String?
  private var reactionPickerMessageId: String?
  private var selectionModeEnabled: Bool = false
  private var selectedMessageIds: Set<String> = []
  private var pinnedBannerHeightConstraint: NSLayoutConstraint?
  private var pinnedBannerHostingController: UIHostingController<PinnedMessageBannerView>?
  private var scrollToBottomHostingController: UIHostingController<ConversationScrollToBottomButtonView>?
  private var activePinnedBannerMessageId: String?
  private var lastVisiblePinnedBannerHeadMessageId: String?
  private var preservesPinnedBannerSelectionUntilManualScroll: Bool = false
  private var revealedPinnedRemovalMessageId: String?
  private var highlightedMessageId: String?
  private var highlightResetTask: Task<Void, Never>?
  private var lastRenderedLatestMessageId: String?
  private var willResignActiveObserver: NSObjectProtocol?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var previewedAttachment: PreparedAttachmentPreview?
  private var previewedAttachmentSourceMessageId: String?
  private var activeAttachmentOperation: AttachmentOperation?
  private var callButtonItem: UIBarButtonItem?
  private var presentedIncomingCallIds: Set<String> = []
  #if DEBUG
  private var autoProtectConversationTask: Task<Void, Never>?
  #endif

  private let reactionEmojis: [String] = ["👍", "❤️", "😂", "😮", "😢", "🔥"]
  private let attachmentLogger: Logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.example.messenger",
    category: "AttachmentPreview"
  )

  private var displayedMessages: [Message] {
    viewModel.visibleMessages()
  }

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

    updateTitle()
    configureDefaultNavigationItems()
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.conversation(viewModel.conversation.id)

    viewModel.onStateChanged = { [weak self] in
      self?.applyStateUpdate()
    }

    configureApplicationStateObservers()
    configureLayout()

    Task {
      await viewModel.joinRealtime()
      try? await viewModel.loadConversationDetails()
      try? await viewModel.loadInitialMessages()
      await refreshTypingState()
      updateSecurityBanner()
      updatePinnedMessageBanner()
      tableView.reloadData()
      updateTitle()
      scrollToLatestMessage(animated: false)
      updatePinnedMessageBanner()
      updateScrollToBottomButtonVisibility()
      presentIncomingCallPromptIfNeeded()
      autoProtectConversationForUITestsIfNeeded()
      lastRenderedLatestMessageId = displayedMessages.last?.id
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)

    Task {
      await viewModel.beginVisibleConversationTracking()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)

    Task {
      await viewModel.endVisibleConversationTracking()
    }
  }

  deinit {
    highlightResetTask?.cancel()
    #if DEBUG
    autoProtectConversationTask?.cancel()
    #endif

    let notificationCenter = NotificationCenter.default
    if let willResignActiveObserver {
      notificationCenter.removeObserver(willResignActiveObserver)
    }
    if let didBecomeActiveObserver {
      notificationCenter.removeObserver(didBecomeActiveObserver)
    }

    let viewModel: ConversationViewModel = self.viewModel
    Task {
      await viewModel.endVisibleConversationTracking()
      await viewModel.leaveRealtime()
    }
  }

  private func configureApplicationStateObservers() {
    let notificationCenter = NotificationCenter.default

    willResignActiveObserver = notificationCenter.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else {
        return
      }

      Task {
        await self.viewModel.endVisibleConversationTracking()
      }
    }

    didBecomeActiveObserver = notificationCenter.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.restoreVisibleConversationTrackingIfNeeded()
      }
    }
  }

  private func restoreVisibleConversationTrackingIfNeeded() {
    guard isViewLoaded,
      view.window != nil,
      navigationController?.topViewController === self
    else {
      return
    }

    Task {
      await viewModel.beginVisibleConversationTracking()
    }
  }

  private func configureLayout() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ConversationMessageCell.self, forCellReuseIdentifier: "message")
    tableView.keyboardDismissMode = .interactive
    tableView.allowsMultipleSelectionDuringEditing = true
    tableView.accessibilityIdentifier = MessengerAccessibility.View.conversationMessagesList
    TelegramStyle.styleTableView(tableView)
    let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleMessageLongPress(_:)))
    longPressRecognizer.minimumPressDuration = 0.4
    tableView.addGestureRecognizer(longPressRecognizer)

    securityBannerView.backgroundColor = TelegramStyle.warningColor.withAlphaComponent(0.12)
    securityBannerView.layer.cornerRadius = 10
    securityBannerView.layer.borderWidth = 1
    securityBannerView.layer.borderColor = TelegramStyle.warningColor.withAlphaComponent(0.42).cgColor
    securityBannerView.translatesAutoresizingMaskIntoConstraints = false
    securityBannerView.isHidden = true
    securityBannerView.accessibilityIdentifier = MessengerAccessibility.View.conversationSecurityBanner

    securityBannerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    securityBannerLabel.numberOfLines = 0
    securityBannerLabel.textColor = TelegramStyle.warningColor

    verifyKeyButton.setTitle("Проверить ключ", for: .normal)
    verifyKeyButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
    verifyKeyButton.setTitleColor(TelegramStyle.accentColor, for: .normal)
    verifyKeyButton.addTarget(self, action: #selector(verifyKeyTapped), for: .touchUpInside)
    verifyKeyButton.accessibilityIdentifier = MessengerAccessibility.Button.conversationVerifyKey

    let bannerStack: UIStackView = UIStackView(arrangedSubviews: [securityBannerLabel, verifyKeyButton])
    bannerStack.axis = .horizontal
    bannerStack.spacing = 8
    bannerStack.alignment = .top
    bannerStack.translatesAutoresizingMaskIntoConstraints = false
    securityBannerView.addSubview(bannerStack)

    NSLayoutConstraint.activate([
      bannerStack.leadingAnchor.constraint(equalTo: securityBannerView.leadingAnchor, constant: 10),
      bannerStack.trailingAnchor.constraint(equalTo: securityBannerView.trailingAnchor, constant: -10),
      bannerStack.topAnchor.constraint(equalTo: securityBannerView.topAnchor, constant: 8),
      bannerStack.bottomAnchor.constraint(equalTo: securityBannerView.bottomAnchor, constant: -8),
      verifyKeyButton.widthAnchor.constraint(equalToConstant: 116),
    ])

    typingLabel.textColor = TelegramStyle.textSecondaryColor
    typingLabel.font = .systemFont(ofSize: 13)
    typingLabel.numberOfLines = 1
    typingLabel.text = ""
    typingLabel.accessibilityIdentifier = MessengerAccessibility.Label.conversationTyping

    pinnedBannerContainer.translatesAutoresizingMaskIntoConstraints = false
    pinnedBannerContainer.backgroundColor = .clear
    pinnedBannerContainer.isHidden = true
    pinnedBannerContainer.setContentHuggingPriority(.required, for: .vertical)
    pinnedBannerContainer.setContentCompressionResistancePriority(.required, for: .vertical)
    pinnedBannerHeightConstraint = pinnedBannerContainer.heightAnchor.constraint(equalToConstant: 0)
    pinnedBannerHeightConstraint?.isActive = true
    configurePinnedBannerHosting()

    scrollToBottomContainer.translatesAutoresizingMaskIntoConstraints = false
    scrollToBottomContainer.backgroundColor = .clear
    scrollToBottomContainer.isHidden = true

    composerContainer.translatesAutoresizingMaskIntoConstraints = false
    TelegramStyle.styleGlassCard(composerContainer, cornerRadius: 16)

    replyPreviewContainer.translatesAutoresizingMaskIntoConstraints = false
    replyPreviewContainer.backgroundColor = TelegramStyle.surfaceElevatedColor.withAlphaComponent(0.75)
    replyPreviewContainer.layer.cornerRadius = 10
    replyPreviewContainer.layer.borderWidth = 1
    replyPreviewContainer.layer.borderColor = TelegramStyle.borderColor.cgColor
    replyPreviewContainer.isHidden = true

    replyPreviewLabel.font = .systemFont(ofSize: 12, weight: .medium)
    replyPreviewLabel.textColor = TelegramStyle.textSecondaryColor
    replyPreviewLabel.numberOfLines = 2

    clearReplyButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    clearReplyButton.tintColor = TelegramStyle.textSecondaryColor
    clearReplyButton.addTarget(self, action: #selector(clearReplyTapped), for: .touchUpInside)

    let replyStack: UIStackView = UIStackView(arrangedSubviews: [replyPreviewLabel, clearReplyButton])
    replyStack.axis = .horizontal
    replyStack.spacing = 8
    replyStack.alignment = .center
    replyStack.translatesAutoresizingMaskIntoConstraints = false
    replyPreviewContainer.addSubview(replyStack)

    NSLayoutConstraint.activate([
      replyStack.leadingAnchor.constraint(equalTo: replyPreviewContainer.leadingAnchor, constant: 10),
      replyStack.trailingAnchor.constraint(equalTo: replyPreviewContainer.trailingAnchor, constant: -8),
      replyStack.topAnchor.constraint(equalTo: replyPreviewContainer.topAnchor, constant: 8),
      replyStack.bottomAnchor.constraint(equalTo: replyPreviewContainer.bottomAnchor, constant: -8),
      clearReplyButton.widthAnchor.constraint(equalToConstant: 22),
    ])

    sendButton.setImage(UIImage(systemName: "paperplane.fill"), for: .normal)
    sendButton.tintColor = TelegramStyle.accentColor
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    sendButton.accessibilityIdentifier = MessengerAccessibility.Button.conversationSend

    attachButton.setImage(UIImage(systemName: "paperclip.circle.fill"), for: .normal)
    attachButton.tintColor = TelegramStyle.accentSecondary
    attachButton.addTarget(self, action: #selector(attachTapped), for: .touchUpInside)
    attachButton.accessibilityIdentifier = MessengerAccessibility.Button.conversationAttach
    inputField.accessibilityIdentifier = MessengerAccessibility.Input.conversationText

    let composerRow: UIStackView = UIStackView(arrangedSubviews: [attachButton, inputField, sendButton])
    composerRow.axis = .horizontal
    composerRow.spacing = 8
    composerRow.alignment = .center

    let composerStack: UIStackView = UIStackView(arrangedSubviews: [replyPreviewContainer, composerRow])
    composerStack.axis = .vertical
    composerStack.spacing = 8
    composerStack.translatesAutoresizingMaskIntoConstraints = false

    composerContainer.addSubview(composerStack)

    let rootStack: UIStackView = UIStackView(
      arrangedSubviews: [securityBannerView, pinnedBannerContainer, tableView, typingLabel, composerContainer]
    )
    rootStack.axis = .vertical
    rootStack.spacing = 4
    rootStack.translatesAutoresizingMaskIntoConstraints = false

    attachmentLoadingContainer.translatesAutoresizingMaskIntoConstraints = false
    attachmentLoadingContainer.isHidden = true
    TelegramStyle.styleGlassCard(attachmentLoadingContainer, cornerRadius: 14)

    attachmentLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
    attachmentLoadingIndicator.hidesWhenStopped = true
    attachmentLoadingIndicator.color = TelegramStyle.accentColor

    attachmentLoadingLabel.translatesAutoresizingMaskIntoConstraints = false
    attachmentLoadingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    attachmentLoadingLabel.textColor = TelegramStyle.textPrimaryColor
    attachmentLoadingLabel.numberOfLines = 1

    let attachmentLoadingStack: UIStackView = UIStackView(arrangedSubviews: [attachmentLoadingIndicator, attachmentLoadingLabel])
    attachmentLoadingStack.axis = .horizontal
    attachmentLoadingStack.spacing = 10
    attachmentLoadingStack.alignment = .center
    attachmentLoadingStack.translatesAutoresizingMaskIntoConstraints = false
    attachmentLoadingContainer.addSubview(attachmentLoadingStack)

    view.addSubview(rootStack)
    view.addSubview(scrollToBottomContainer)
    view.addSubview(attachmentLoadingContainer)

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      rootStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

      composerStack.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: 12),
      composerStack.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -12),
      composerStack.topAnchor.constraint(equalTo: composerContainer.topAnchor, constant: 8),
      composerStack.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -8),

      attachButton.widthAnchor.constraint(equalToConstant: 34),
      sendButton.widthAnchor.constraint(equalToConstant: 34),
      typingLabel.heightAnchor.constraint(equalToConstant: 20),

      attachmentLoadingStack.leadingAnchor.constraint(equalTo: attachmentLoadingContainer.leadingAnchor, constant: 14),
      attachmentLoadingStack.trailingAnchor.constraint(equalTo: attachmentLoadingContainer.trailingAnchor, constant: -14),
      attachmentLoadingStack.topAnchor.constraint(equalTo: attachmentLoadingContainer.topAnchor, constant: 10),
      attachmentLoadingStack.bottomAnchor.constraint(equalTo: attachmentLoadingContainer.bottomAnchor, constant: -10),

      attachmentLoadingContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      attachmentLoadingContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      attachmentLoadingContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
    ])

    configureScrollToBottomButton()
  }

  private func configurePinnedBannerHosting() {
    let hostingController = UIHostingController(rootView: makePinnedBannerView(state: nil))
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear
    hostingController.view.setContentHuggingPriority(.required, for: .vertical)
    hostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)

    addChild(hostingController)
    pinnedBannerContainer.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: pinnedBannerContainer.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: pinnedBannerContainer.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: pinnedBannerContainer.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: pinnedBannerContainer.bottomAnchor),
    ])
    hostingController.didMove(toParent: self)
    pinnedBannerHostingController = hostingController
  }

  private func configureScrollToBottomButton() {
    let hostingController = UIHostingController(rootView: makeScrollToBottomButtonView())
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear
    hostingController.view.alpha = 0

    addChild(hostingController)
    scrollToBottomContainer.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      scrollToBottomContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      scrollToBottomContainer.bottomAnchor.constraint(equalTo: composerContainer.topAnchor, constant: -14),
      hostingController.view.leadingAnchor.constraint(equalTo: scrollToBottomContainer.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: scrollToBottomContainer.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: scrollToBottomContainer.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: scrollToBottomContainer.bottomAnchor),
    ])
    hostingController.didMove(toParent: self)
    scrollToBottomHostingController = hostingController
  }

  private func makePinnedBannerView(state: PinnedMessageBannerState?) -> PinnedMessageBannerView {
    PinnedMessageBannerView(
      state: state,
      onPrimaryTap: { [weak self] messageId in
        self?.handlePinnedBannerPrimaryTap(messageId: messageId)
      },
      onSecondaryTap: { [weak self] messageId in
        self?.handlePinnedBannerSecondaryTap(messageId: messageId)
      },
      onDismissTap: { [weak self] messageId in
        self?.handlePinnedBannerDismissTap(messageId: messageId)
      }
    )
  }

  private func makeScrollToBottomButtonView() -> ConversationScrollToBottomButtonView {
    ConversationScrollToBottomButtonView { [weak self] in
      self?.handleScrollToBottomTapped()
    }
  }

  private func updatePinnedMessageBanner() {
    let pinnedMessages: [PinnedMessage] = viewModel.visiblePinnedMessages()
    let latestPinnedMessageId: String? = pinnedMessages.first?.messageId

    if latestPinnedMessageId != lastVisiblePinnedBannerHeadMessageId {
      activePinnedBannerMessageId = latestPinnedMessageId
      preservesPinnedBannerSelectionUntilManualScroll = false
    }

    guard let activePinnedMessage: PinnedMessage = resolvedPinnedBannerMessage(from: pinnedMessages) else {
      activePinnedBannerMessageId = nil
      lastVisiblePinnedBannerHeadMessageId = nil
      preservesPinnedBannerSelectionUntilManualScroll = false
      revealedPinnedRemovalMessageId = nil
      pinnedBannerContainer.isHidden = true
      pinnedBannerHeightConstraint?.constant = 0
      pinnedBannerHostingController?.rootView = makePinnedBannerView(state: nil)
      return
    }

    activePinnedBannerMessageId = activePinnedMessage.messageId
    lastVisiblePinnedBannerHeadMessageId = latestPinnedMessageId
    if revealedPinnedRemovalMessageId != activePinnedMessage.messageId {
      revealedPinnedRemovalMessageId = nil
    }

    let activeIndex: Int = pinnedMessages.firstIndex(where: { $0.messageId == activePinnedMessage.messageId }) ?? 0
    let state = PinnedMessageBannerState(
      messageId: activePinnedMessage.messageId,
      previewText: viewModel.pinnedMessagePreviewText(activePinnedMessage.messageId),
      additionalPinnedCount: max(0, pinnedMessages.count - activeIndex - 1),
      showsDismissButton: revealedPinnedRemovalMessageId == activePinnedMessage.messageId
    )
    pinnedBannerContainer.isHidden = false
    pinnedBannerHeightConstraint?.constant = state.showsDismissButton ? 122 : 68
    pinnedBannerHostingController?.rootView = makePinnedBannerView(state: state)
  }

  private func resolvedPinnedBannerMessage(from pinnedMessages: [PinnedMessage]) -> PinnedMessage? {
    guard !pinnedMessages.isEmpty else {
      return nil
    }

    if preservesPinnedBannerSelectionUntilManualScroll,
      let activePinnedBannerMessageId,
      let pinnedMessage: PinnedMessage = pinnedMessages.first(where: { $0.messageId == activePinnedBannerMessageId })
    {
      return pinnedMessage
    }

    let fallbackPinnedMessage: PinnedMessage? = defaultPinnedBannerMessage(from: pinnedMessages)
    activePinnedBannerMessageId = fallbackPinnedMessage?.messageId
    return fallbackPinnedMessage
  }

  private func defaultPinnedBannerMessage(from pinnedMessages: [PinnedMessage]) -> PinnedMessage? {
    guard !pinnedMessages.isEmpty else {
      return nil
    }

    guard let bottomVisibleMessageDate: Date = currentBottomVisibleMessageDate() else {
      return pinnedMessages.first
    }

    if let matchedPinnedMessage: PinnedMessage = pinnedMessages.first(where: {
      viewModel.pinnedMessageSentAt($0) <= bottomVisibleMessageDate
    }) {
      return matchedPinnedMessage
    }

    return pinnedMessages.last
  }

  private func currentBottomVisibleMessageDate() -> Date? {
    guard let visibleRows: [IndexPath] = tableView.indexPathsForVisibleRows,
      let bottomVisibleIndexPath: IndexPath = visibleRows.max(by: { $0.row < $1.row }),
      displayedMessages.indices.contains(bottomVisibleIndexPath.row)
    else {
      return nil
    }

    return displayedMessages[bottomVisibleIndexPath.row].createdAt
  }

  private func clearPinnedBannerSelectionOverride() {
    preservesPinnedBannerSelectionUntilManualScroll = false
    activePinnedBannerMessageId = nil
  }

  private func handlePinnedBannerPrimaryTap(messageId: String) {
    guard let pinnedMessage: PinnedMessage = resolvedPinnedBannerMessage(from: viewModel.visiblePinnedMessages()),
      pinnedMessage.messageId == messageId
    else {
      return
    }

    if revealedPinnedRemovalMessageId == messageId {
      presentPinnedUnpinOptions(for: pinnedMessage)
      return
    }

    Task {
      await openPinnedMessage(messageId: messageId)
    }
  }

  private func handlePinnedBannerSecondaryTap(messageId: String) {
    guard let pinnedMessage: PinnedMessage = resolvedPinnedBannerMessage(from: viewModel.visiblePinnedMessages()),
      pinnedMessage.messageId == messageId
    else {
      return
    }

    if revealedPinnedRemovalMessageId == messageId {
      presentPinnedUnpinOptions(for: pinnedMessage)
      return
    }

    revealedPinnedRemovalMessageId = messageId
    updatePinnedMessageBanner()
  }

  private func handlePinnedBannerDismissTap(messageId: String) {
    guard let pinnedMessage: PinnedMessage = resolvedPinnedBannerMessage(from: viewModel.visiblePinnedMessages()),
      pinnedMessage.messageId == messageId
    else {
      return
    }

    presentPinnedUnpinOptions(for: pinnedMessage)
  }

  private func presentPinnedUnpinOptions(for pinnedMessage: PinnedMessage) {
    let sheet = UIAlertController(
      title: "Открепить сообщение",
      message: viewModel.pinnedMessagePreviewText(pinnedMessage.messageId),
      preferredStyle: .actionSheet
    )

    sheet.addAction(
      UIAlertAction(title: "Открепить для себя", style: .destructive) { [weak self] _ in
        self?.revealedPinnedRemovalMessageId = nil
        self?.viewModel.unpinMessageForCurrentUser(messageId: pinnedMessage.messageId)
      }
    )

    if viewModel.canUnpinMessageForEveryone(pinnedMessage) {
      sheet.addAction(
        UIAlertAction(title: "Открепить для всех", style: .destructive) { [weak self] _ in
          self?.performPinnedUnpinForEveryone(messageId: pinnedMessage.messageId)
        }
      )
    }

    sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))

    if let popover: UIPopoverPresentationController = sheet.popoverPresentationController {
      popover.sourceView = pinnedBannerContainer
      popover.sourceRect = pinnedBannerContainer.bounds
    }

    present(sheet, animated: true)
  }

  private func performPinnedUnpinForEveryone(messageId: String) {
    revealedPinnedRemovalMessageId = nil
    Task {
      do {
        try await viewModel.unpinMessage(messageId: messageId)
      } catch {
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  private func openPinnedMessage(messageId: String) async {
    guard let indexPath: IndexPath = await ensureMessageVisible(messageId: messageId) else {
      showErrorAlert(message: "Не удалось найти закреплённое сообщение")
      return
    }

    tableView.layoutIfNeeded()
    tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
    highlightMessage(messageId: messageId)
    advancePinnedBanner(afterShowing: messageId)
  }

  private func advancePinnedBanner(afterShowing messageId: String) {
    let pinnedMessages: [PinnedMessage] = viewModel.visiblePinnedMessages()
    guard let currentIndex: Int = pinnedMessages.firstIndex(where: { $0.messageId == messageId }) else {
      return
    }

    let nextIndex: Int = currentIndex + 1
    if pinnedMessages.indices.contains(nextIndex) {
      activePinnedBannerMessageId = pinnedMessages[nextIndex].messageId
    } else {
      activePinnedBannerMessageId = messageId
    }
    preservesPinnedBannerSelectionUntilManualScroll = true
    revealedPinnedRemovalMessageId = nil
    updatePinnedMessageBanner()
  }

  private func ensureMessageVisible(messageId: String) async -> IndexPath? {
    var previousVisibleCount: Int = -1

    while true {
      if let indexPath: IndexPath = indexPath(forMessageId: messageId) {
        return indexPath
      }

      let currentVisibleCount: Int = displayedMessages.count
      guard currentVisibleCount != previousVisibleCount else {
        return nil
      }
      previousVisibleCount = currentVisibleCount

      do {
        try await viewModel.loadMoreMessages()
      } catch {
        return nil
      }

      tableView.reloadData()
      updatePinnedMessageBanner()
      updateScrollToBottomButtonVisibility()
      await Task.yield()
    }
  }

  private func indexPath(forMessageId messageId: String) -> IndexPath? {
    guard let index: Int = displayedMessages.firstIndex(where: { $0.id == messageId }) else {
      return nil
    }

    return IndexPath(row: index, section: 0)
  }

  private func highlightMessage(messageId: String) {
    highlightResetTask?.cancel()
    highlightedMessageId = messageId

    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard let currentIndexPath: IndexPath = self.indexPath(forMessageId: messageId) else {
        return
      }

      self.tableView.reloadRows(at: [currentIndexPath], with: .none)
      self.tableView.layoutIfNeeded()
      if let cell = self.tableView.cellForRow(at: currentIndexPath) as? ConversationMessageCell {
        cell.flashHighlight()
      }
    }

    highlightResetTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 2_400_000_000)
      guard let self, self.highlightedMessageId == messageId else {
        return
      }

      self.highlightedMessageId = nil
      if let currentIndexPath: IndexPath = self.indexPath(forMessageId: messageId) {
        self.tableView.reloadRows(at: [currentIndexPath], with: .none)
      } else {
        self.tableView.reloadData()
      }
    }
  }

  private func beginAttachmentOperation(_ operation: AttachmentOperation) -> Bool {
    guard activeAttachmentOperation == nil else {
      return false
    }

    activeAttachmentOperation = operation
    attachmentLoadingLabel.text = operation.loadingText
    attachmentLoadingContainer.isHidden = false
    attachmentLoadingIndicator.startAnimating()
    return true
  }

  private func finishAttachmentOperation() {
    activeAttachmentOperation = nil
    attachmentLoadingIndicator.stopAnimating()
    attachmentLoadingContainer.isHidden = true
    attachmentLoadingLabel.text = nil
  }

  private func clearPreviewedAttachmentState() {
    previewedAttachment = nil
    previewedAttachmentSourceMessageId = nil
  }

  private func sourceBubbleView(for messageId: String) -> UIView? {
    guard let index: Int = displayedMessages.firstIndex(where: { $0.id == messageId }) else {
      return nil
    }

    let indexPath = IndexPath(row: index, section: 0)
    guard let cell = tableView.cellForRow(at: indexPath) as? ConversationMessageCell else {
      return nil
    }

    return cell.previewTransitionView
  }

  private func configureAttachmentPopover(_ controller: UIActivityViewController, messageId: String) {
    guard let popover = controller.popoverPresentationController else {
      return
    }

    if let sourceView: UIView = sourceBubbleView(for: messageId) {
      popover.sourceView = sourceView
      popover.sourceRect = sourceView.bounds
      return
    }

    popover.sourceView = view
    popover.sourceRect = CGRect(
      x: view.bounds.midX,
      y: view.bounds.midY,
      width: 1,
      height: 1
    )
  }

  private func logAttachmentPresentTiming(kind: String, startedAt: TimeInterval) {
    #if DEBUG
    let elapsedMs: Int = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
    attachmentLogger.debug("\(kind, privacy: .public) present_ms=\(elapsedMs)")
    #endif
  }

  private func applyStateUpdate() {
    let previousLatestMessageId: String? = lastRenderedLatestMessageId
    if let reactionPickerMessageId,
      !displayedMessages.contains(where: { $0.id == reactionPickerMessageId })
    {
      self.reactionPickerMessageId = nil
    }
    updateTitle()
    updateSecurityBanner()
    tableView.reloadData()
    reselectRowsIfNeeded()
    let currentLatestMessageId: String? = displayedMessages.last?.id
    if shouldAutoScroll(previousLatestMessageId: previousLatestMessageId, currentLatestMessageId: currentLatestMessageId) {
      scrollToLatestMessage(animated: previousLatestMessageId != nil)
    }
    updatePinnedMessageBanner()
    updateScrollToBottomButtonVisibility()
    presentIncomingCallPromptIfNeeded()
    autoProtectConversationForUITestsIfNeeded()
    lastRenderedLatestMessageId = currentLatestMessageId
    Task {
      await refreshTypingState()
    }
  }

  private func shouldAutoScroll(previousLatestMessageId: String?, currentLatestMessageId: String?) -> Bool {
    guard let currentLatestMessageId else {
      return false
    }

    guard let previousLatestMessageId else {
      return true
    }

    return currentLatestMessageId != previousLatestMessageId
  }

  private func scrollToLatestMessage(animated: Bool) {
    guard !displayedMessages.isEmpty else {
      return
    }

    clearPinnedBannerSelectionOverride()
    let indexPath: IndexPath = IndexPath(row: displayedMessages.count - 1, section: 0)
    tableView.layoutIfNeeded()
    tableView.scrollToRow(at: indexPath, at: .bottom, animated: animated)
    updateScrollToBottomButtonVisibility()
  }

  private func handleScrollToBottomTapped() {
    dismissReactionPicker()
    scrollToLatestMessage(animated: true)
    updatePinnedMessageBanner()
  }

  private func updateScrollToBottomButtonVisibility() {
    let shouldShowButton: Bool = isScrolledMoreThanOneViewportFromBottom()

    guard let scrollToBottomView: UIView = scrollToBottomHostingController?.view else {
      scrollToBottomContainer.isHidden = !shouldShowButton
      return
    }

    if shouldShowButton == !scrollToBottomContainer.isHidden {
      return
    }

    if shouldShowButton {
      scrollToBottomContainer.isHidden = false
    }

    UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
      scrollToBottomView.alpha = shouldShowButton ? 1 : 0
    } completion: { [weak self] _ in
      self?.scrollToBottomContainer.isHidden = !shouldShowButton
    }
  }

  private func isScrolledMoreThanOneViewportFromBottom() -> Bool {
    let thresholdHeight: CGFloat = max(tableView.bounds.height, view.bounds.height)
    guard thresholdHeight > 0 else {
      return false
    }

    let bottomInset: CGFloat = tableView.adjustedContentInset.bottom
    let visibleBottomY: CGFloat = tableView.contentOffset.y + tableView.bounds.height - bottomInset
    let distanceToBottom: CGFloat = tableView.contentSize.height - visibleBottomY
    return distanceToBottom > thresholdHeight
  }

  private func setReactionPickerMessageId(_ messageId: String?) {
    let normalizedMessageId: String? = messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard reactionPickerMessageId != normalizedMessageId else {
      return
    }

    let previousMessageId: String? = reactionPickerMessageId
    reactionPickerMessageId = normalizedMessageId

    var rowsToReload: [IndexPath] = []
    if let previousMessageId,
      let previousIndex: Int = displayedMessages.firstIndex(where: { $0.id == previousMessageId })
    {
      rowsToReload.append(IndexPath(row: previousIndex, section: 0))
    }

    if let normalizedMessageId,
      let currentIndex: Int = displayedMessages.firstIndex(where: { $0.id == normalizedMessageId })
    {
      rowsToReload.append(IndexPath(row: currentIndex, section: 0))
    }

    let uniqueRows: [IndexPath] = Array(Set(rowsToReload)).sorted(by: { $0.row < $1.row })
    guard !uniqueRows.isEmpty else {
      return
    }

    tableView.reloadRows(at: uniqueRows, with: .none)
  }

  private func dismissReactionPicker() {
    setReactionPickerMessageId(nil)
  }

  @objc
  private func handleMessageLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
    guard gestureRecognizer.state == .began,
      !tableView.isEditing
    else {
      return
    }

    let touchPoint: CGPoint = gestureRecognizer.location(in: tableView)
    guard let indexPath: IndexPath = tableView.indexPathForRow(at: touchPoint),
      displayedMessages.indices.contains(indexPath.row)
    else {
      dismissReactionPicker()
      return
    }

    let message: Message = displayedMessages[indexPath.row]
    setReactionPickerMessageId(message.id)
  }

  private func updateTitle() {
    title = UserHandleDisplay.title(for: viewModel.conversation, currentUserId: viewModel.activeUserId)
  }

  private func configureDefaultNavigationItems() {
    guard viewModel.conversation.type == .direct else {
      navigationItem.rightBarButtonItem = nil
      callButtonItem = nil
      return
    }

    let item = UIBarButtonItem(
      image: UIImage(systemName: "phone.fill"),
      style: .plain,
      target: self,
      action: #selector(startCallTapped)
    )
    item.accessibilityIdentifier = MessengerAccessibility.Button.conversationStartCall
    item.accessibilityLabel = "Начать защищенный звонок"
    navigationItem.rightBarButtonItem = item
    callButtonItem = item
  }

  @objc
  private func startCallTapped() {
    guard viewModel.conversation.type == .direct, viewModel.peerUserId != nil else {
      showErrorAlert(message: "Звонок доступен только в личном диалоге.")
      return
    }

    guard viewModel.isConversationProtected else {
      showErrorAlert(message: "Перед звонком проверьте ключ контакта. Звонки разрешены только для protected trust state.")
      return
    }

    let sheet = UIAlertController(title: "Защищенный звонок", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "Аудиозвонок", style: .default) { [weak self] _ in
      guard let self else {
        return
      }
      self.onStartCall?(self.viewModel, .voice)
    })
    sheet.addAction(UIAlertAction(title: "Видеозвонок", style: .default) { [weak self] _ in
      guard let self else {
        return
      }
      self.onStartCall?(self.viewModel, .video)
    })
    sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      popover.barButtonItem = callButtonItem
    }

    present(sheet, animated: true)
  }

  private func presentIncomingCallPromptIfNeeded() {
    guard viewModel.conversation.type == .direct,
      view.window != nil,
      let incomingCall: IncomingConversationCall = latestIncomingCallOffer(),
      !presentedIncomingCallIds.contains(incomingCall.offer.callId)
    else {
      return
    }

    presentedIncomingCallIds.insert(incomingCall.offer.callId)
    let descriptor = E2EIncomingCallDescriptor(
      systemUUID: UUID(),
      callId: incomingCall.offer.callId,
      conversation: viewModel.conversation,
      offer: incomingCall.offer,
      callType: incomingCall.callType,
      callerUserId: incomingCall.callerUserId
    )
    SystemCallCoordinator.shared.reportIncomingCall(descriptor)
  }

  private struct IncomingConversationCall {
    let offer: CallSessionDescriptionSignal
    let callType: Call.CallType
    let callerUserId: String
  }

  private func latestIncomingCallOffer() -> IncomingConversationCall? {
    let currentUserId: String? = viewModel.activeUserId?.lowercased()
    var closedCallIds: Set<String> = []

    let rawMessages: [Message] = viewModel.messages.sorted(by: { $0.createdAt < $1.createdAt })
    for message in rawMessages.reversed() {
      guard let payload: [String: Any] = parseJSONObject(from: message.content),
        let callId: String = stringValue(payload["call_id"] ?? payload["callId"]),
        !callId.isEmpty
      else {
        continue
      }

      if message.type == .callEnd {
        closedCallIds.insert(callId)
        continue
      }

      if let currentUserId, message.senderId.lowercased() == currentUserId {
        continue
      }

      guard message.type == .callOffer, !closedCallIds.contains(callId) else {
        continue
      }

      guard CallSignalParser.isInitialOffer(payload) else {
        continue
      }

      guard let descriptor: E2EIncomingCallDescriptor = CallSignalParser.incomingCallDescriptor(
        from: message,
        conversation: viewModel.conversation,
        currentUserId: viewModel.activeUserId,
        localDeviceId: viewModel.activeDeviceId
      ) else {
        continue
      }

      return IncomingConversationCall(
        offer: descriptor.offer,
        callType: descriptor.callType,
        callerUserId: descriptor.callerUserId
      )
    }

    return nil
  }

  private func parseJSONObject(from raw: String) -> [String: Any]? {
    guard let data: Data = raw.data(using: .utf8),
      let object: Any = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload: [String: Any] = object as? [String: Any]
    else {
      return nil
    }

    return payload
  }

  private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    default:
      return nil
    }
  }

  private func reselectRowsIfNeeded() {
    guard selectionModeEnabled else {
      return
    }

    for (index, message) in displayedMessages.enumerated() where selectedMessageIds.contains(message.id) {
      tableView.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none)
    }
  }

  private func refreshTypingState() async {
    let count: Int = viewModel.typingUserIds.count
    if count == 0 {
      typingLabel.text = ""
    } else if count == 1 {
      typingLabel.text = "Печатает 1 пользователь..."
    } else {
      typingLabel.text = "Печатают \(count) пользователей..."
    }
  }

  private func updateSecurityBanner() {
    let warningText: String? = viewModel.securityWarningText
    securityBannerView.isHidden = warningText == nil
    securityBannerLabel.text = warningText
    verifyKeyButton.isHidden = warningText == nil
  }

  private func autoProtectConversationForUITestsIfNeeded() {
    #if DEBUG
    guard shouldAutoProtectConversationForUITests(),
      autoProtectConversationTask == nil,
      viewModel.conversation.type == .direct,
      viewModel.peerUserId != nil,
      !viewModel.isConversationProtected
    else {
      return
    }

    autoProtectConversationTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        try await self.viewModel.setAutoKeyExchangeConsent(enabled: true)
        let fingerprint: String = try await self.viewModel.fetchPeerFingerprint()
        try await self.viewModel.verifyPeerFingerprint(fingerprint, method: .p2p)
      } catch {
        self.attachmentLogger.error("ui_test_auto_protect_failed error=\(error.localizedDescription, privacy: .public)")
      }

      self.autoProtectConversationTask = nil
    }
    #endif
  }

  private func shouldAutoProtectConversationForUITests() -> Bool {
    #if DEBUG
    let environment: [String: String] = ProcessInfo.processInfo.environment
    guard environment["UITEST_MODE"] == "1" else {
      return false
    }

    switch (environment["E2E_AUTO_PROTECT_CONVERSATION"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
      return true
    default:
      return false
    }
    #else
    return false
    #endif
  }

  @objc
  private func verifyKeyTapped() {
    let sheet: UIAlertController = UIAlertController(title: "Проверка ключа", message: nil, preferredStyle: .actionSheet)

    sheet.addAction(UIAlertAction(title: "Сканировать QR", style: .default, handler: { [weak self] _ in
      guard let self else {
        return
      }

      let scanner: QRScannerViewController = QRScannerViewController()
      scanner.onCodeScanned = { [weak self] value in
        guard let self else {
          return
        }
        let fingerprint: String = self.extractFingerprint(from: value)
        Task {
          do {
            try await self.viewModel.verifyPeerFingerprint(fingerprint, method: .qr)
          } catch {
            self.showErrorAlert(message: "Не удалось проверить ключ по QR")
          }
        }
      }
      self.navigationController?.pushViewController(scanner, animated: true)
    }))

    sheet.addAction(UIAlertAction(title: "Ввести fingerprint", style: .default, handler: { [weak self] _ in
      self?.showInputAlert(title: "Fingerprint", placeholder: "SHA-256") { value in
        Task {
          do {
            try await self?.viewModel.verifyPeerFingerprint(value.trimmingCharacters(in: .whitespacesAndNewlines), method: .manual)
          } catch {
            self?.showErrorAlert(message: "Не удалось подтвердить fingerprint")
          }
        }
      }
    }))

    sheet.addAction(UIAlertAction(title: "Включить автообмен P2P", style: .default, handler: { [weak self] _ in
      Task {
        do {
          try await self?.viewModel.setAutoKeyExchangeConsent(enabled: true)
        } catch {
          self?.showErrorAlert(message: "Не удалось включить автообмен")
        }
      }
    }))

    sheet.addAction(UIAlertAction(title: "Показать fingerprint собеседника", style: .default, handler: { [weak self] _ in
      Task {
        do {
          if let fingerprint: String = try await self?.viewModel.fetchPeerFingerprint() {
            self?.showErrorAlert(message: fingerprint, title: "Fingerprint собеседника")
          }
        } catch {
          self?.showErrorAlert(message: "Не удалось получить fingerprint")
        }
      }
    }))

    sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))

    if let popover: UIPopoverPresentationController = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: 64, width: 1, height: 1)
    }

    present(sheet, animated: true)
  }

  private func extractFingerprint(from input: String) -> String {
    let trimmed: String = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let card: QRContactCard = ContactCodeCodec.decode(trimmed) {
      let digest = SHA256.hash(data: Data(card.ikSignPub.utf8))
      return digest.map { String(format: "%02x", $0) }.joined()
    }

    if trimmed.contains(":") {
      return trimmed.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
    }
    return trimmed
  }

  @objc
  private func sendTapped() {
    let text: String = inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else {
      return
    }

    Task {
      do {
        _ = try await viewModel.sendText(
          plaintext: text,
          replyToMessageId: selectedReplyMessageId,
          forwardFromMessageId: nil
        )

        selectedReplyMessageId = nil
        updateReplyPreview()
        inputField.text = nil
      } catch {
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  @objc
  private func clearReplyTapped() {
    selectedReplyMessageId = nil
    updateReplyPreview()
  }

  private func updateReplyPreview() {
    guard let selectedReplyMessageId,
      let preview: String = viewModel.replyPreviewText(messageId: selectedReplyMessageId)
    else {
      replyPreviewContainer.isHidden = true
      replyPreviewLabel.text = nil
      return
    }

    replyPreviewContainer.isHidden = false
    replyPreviewLabel.text = "Ответ на: \(preview.prefix(100))"
  }

  @objc
  private func attachTapped() {
    let picker: UIDocumentPickerViewController = UIDocumentPickerViewController(
      forOpeningContentTypes: [.data],
      asCopy: true
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  private func openAttachmentPreview(for message: Message, allowRiskyPreview: Bool = false) {
    let operation: AttachmentOperation = .preview(messageId: message.id)
    guard beginAttachmentOperation(operation) else {
      return
    }

    Task {
      do {
        let preview: PreparedAttachmentPreview = try await viewModel.prepareAttachmentPreview(
          messageId: message.id,
          allowRiskyPreview: allowRiskyPreview
        )
        previewedAttachment = preview
        previewedAttachmentSourceMessageId = message.id
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        let presentStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        present(controller, animated: true) { [weak self] in
          self?.logAttachmentPresentTiming(kind: "attachment_preview", startedAt: presentStartedAt)
          self?.finishAttachmentOperation()
        }
      } catch let error as AttachmentInspectionError {
        finishAttachmentOperation()
        handleAttachmentInspectionError(error, for: message)
      } catch {
        finishAttachmentOperation()
        clearPreviewedAttachmentState()
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  private func exportAttachment(
    for message: Message,
    allowRiskyPreview: Bool = false,
    allowRiskyExport: Bool = false
  ) {
    let operation: AttachmentOperation = .export(messageId: message.id)
    guard beginAttachmentOperation(operation) else {
      return
    }

    Task {
      do {
        let preview: PreparedAttachmentPreview = try await viewModel.prepareAttachmentExport(
          messageId: message.id,
          allowRiskyPreview: allowRiskyPreview,
          allowRiskyExport: allowRiskyExport
        )
        let activityController = UIActivityViewController(activityItems: [preview.fileURL], applicationActivities: nil)
        configureAttachmentPopover(activityController, messageId: message.id)
        activityController.completionWithItemsHandler = { [weak self] _, _, _, _ in
          self?.clearPreviewedAttachmentState()
        }
        let presentStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
        present(activityController, animated: true) { [weak self] in
          self?.logAttachmentPresentTiming(kind: "attachment_export", startedAt: presentStartedAt)
          self?.finishAttachmentOperation()
        }
      } catch let error as AttachmentInspectionError {
        finishAttachmentOperation()
        handleAttachmentInspectionError(error, for: message)
      } catch {
        finishAttachmentOperation()
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }

  private func handleAttachmentInspectionError(_ error: AttachmentInspectionError, for message: Message) {
    switch error {
    case .previewWarningRequiresAcknowledgement(let result):
      presentAttachmentWarning(
        title: "Рискованное вложение",
        message: result.summary,
        confirmTitle: "Просмотреть"
      ) { [weak self] in
        self?.openAttachmentPreview(for: message, allowRiskyPreview: true)
      }
    case .exportWarningRequiresAcknowledgement(let result):
      presentAttachmentWarning(
        title: "Экспорт рискованного вложения",
        message: result.summary,
        confirmTitle: "Экспортировать"
      ) { [weak self] in
        self?.exportAttachment(for: message, allowRiskyPreview: true, allowRiskyExport: true)
      }
    default:
      showErrorAlert(message: error.localizedDescription)
    }
  }

  private func presentAttachmentWarning(
    title: String,
    message: String,
    confirmTitle: String,
    onConfirm: @escaping () -> Void
  ) {
    let alert = UIAlertController(
      title: title,
      message: "\(message)\n\nПродолжение увеличивает риск утечки или вредоносной активности.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in
      onConfirm()
    })
    present(alert, animated: true)
  }

  private func enterSelectionMode(preselectedMessageId: String? = nil) {
    guard !selectionModeEnabled else {
      return
    }

    dismissReactionPicker()
    selectionModeEnabled = true
    selectedMessageIds.removeAll()
    tableView.setEditing(true, animated: true)
    navigationItem.hidesBackButton = true
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Отмена", style: .plain, target: self, action: #selector(cancelSelectionTapped))
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Переслать (0)",
      style: .done,
      target: self,
      action: #selector(forwardSelectedTapped)
    )
    navigationItem.rightBarButtonItem?.isEnabled = false

    if let preselectedMessageId,
      let index: Int = displayedMessages.firstIndex(where: { $0.id == preselectedMessageId })
    {
      let indexPath = IndexPath(row: index, section: 0)
      tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
      selectedMessageIds.insert(preselectedMessageId)
      updateSelectionNavigationState()
    }
  }

  @objc
  private func cancelSelectionTapped() {
    exitSelectionMode()
  }

  private func exitSelectionMode() {
    dismissReactionPicker()
    selectionModeEnabled = false
    selectedMessageIds.removeAll()
    tableView.setEditing(false, animated: true)
    navigationItem.hidesBackButton = false
    navigationItem.leftBarButtonItem = nil
    configureDefaultNavigationItems()
    tableView.reloadData()
  }

  private func updateSelectionNavigationState() {
    let count: Int = selectedMessageIds.count
    navigationItem.rightBarButtonItem?.title = "Переслать (\(count))"
    navigationItem.rightBarButtonItem?.isEnabled = count > 0
  }

  @objc
  private func forwardSelectedTapped() {
    let ids: [String] = Array(selectedMessageIds)
    guard !ids.isEmpty else {
      return
    }

    openForwardPicker(for: ids)
  }

  private func openForwardPicker(for messageIds: [String]) {
    let picker = ForwardConversationPickerViewController(viewModel: viewModel.makeChatsViewModel())
    picker.onConversationSelected = { [weak self] conversation in
      guard let self else {
        return
      }

      Task {
        do {
          try await self.viewModel.forwardMessages(messageIds: messageIds, to: conversation)
          self.exitSelectionMode()
          self.showErrorAlert(message: "Сообщения пересланы", title: "Готово")
        } catch {
          self.showErrorAlert(message: error.localizedDescription)
        }
      }
    }

    navigationController?.pushViewController(picker, animated: true)
  }

  private func buildMessageViewData(_ message: Message) -> MessageViewData {
    let text: String = message.content
    let isOutgoing: Bool = viewModel.isOutgoing(message)
    let status: String = viewModel.statusSymbol(for: message)
    let timestamp: String = Self.messageTimeFormatter.string(from: message.createdAt)

    var footerParts: [String] = [timestamp]
    if viewModel.hasEdits(messageId: message.id) {
      footerParts.append("изменено")
    }
    if !status.isEmpty {
      footerParts.append(status)
    }
    if message.attachment?.scanVerdict == .warn {
      footerParts.append("риск")
    }

    let replyPreview: String? = {
      guard let replyId: String = message.replyToMessageId else {
        return nil
      }

      if let preview = viewModel.replyPreviewText(messageId: replyId) {
        return String(preview.prefix(100))
      }

      if let fallbackPreview = viewModel.replyPreviewFallback(forReplyMessageId: message.id) {
        return String(fallbackPreview.prefix(100))
      }

      return "Сообщение"
    }()

    let reactionsSummary: String? = {
      guard let reactions: [MessageReaction] = message.reactions,
        !reactions.isEmpty
      else {
        return nil
      }

      var counts: [String: Int] = [:]
      for reaction in reactions {
        counts[reaction.emoji, default: 0] += 1
      }

      let items: [String] = counts
        .sorted(by: { lhs, rhs in lhs.key < rhs.key })
        .map { emoji, count in
          count == 1 ? emoji : "\(emoji) \(count)"
        }

      return items.joined(separator: "  ")
    }()

    let forwardedLabel: String? = {
      guard let forwardedMessageId: String = message.forwardedFromMessageId else {
        return nil
      }

      if let original: Message = viewModel.messages.first(where: { $0.id == forwardedMessageId }) {
        return "Переслано от \(original.senderId)"
      }

      return "Переслано"
    }()

    return MessageViewData(
      id: message.id,
      text: text,
      replyPreview: replyPreview,
      isForwarded: forwardedLabel != nil,
      forwardedText: forwardedLabel,
      reactionsSummary: reactionsSummary,
      footer: footerParts.joined(separator: " • "),
      showEdited: viewModel.hasEdits(messageId: message.id),
      isOutgoing: isOutgoing,
      isDeleted: message.deletedAt != nil
    )
  }

  private func contextActions(for message: Message, includeReactionMenu: Bool = true) -> [UIMenuElement] {
    var actions: [UIMenuElement] = []

    if message.deletedAt == nil, message.attachment != nil {
      actions.append(
        UIAction(
          title: "Просмотреть вложение",
          image: UIImage(systemName: "doc.viewfinder")
        ) { [weak self] _ in
          self?.openAttachmentPreview(for: message)
        }
      )

      actions.append(
        UIAction(
          title: "Экспортировать вложение",
          image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
          self?.exportAttachment(for: message)
        }
      )
    }

    if message.deletedAt == nil {
      if includeReactionMenu {
        let reactionActions: [UIAction] = reactionEmojis.map { emoji in
          UIAction(title: emoji) { [weak self] _ in
            Task {
              do {
                try await self?.viewModel.toggleReaction(messageId: message.id, emoji: emoji)
              } catch {
                self?.showErrorAlert(message: error.localizedDescription)
              }
            }
          }
        }
        actions.append(
          UIMenu(
            title: "Реакция",
            image: UIImage(systemName: "face.smiling"),
            options: .displayInline,
            children: reactionActions
          )
        )
      }

      actions.append(
        UIAction(
          title: "Ответить",
          image: UIImage(systemName: "arrowshape.turn.up.left"),
          identifier: MessengerAccessibility.Action.messageReply
        ) { [weak self] _ in
          self?.selectedReplyMessageId = message.id
          self?.updateReplyPreview()
          self?.inputField.becomeFirstResponder()
        }
      )

      actions.append(
        UIAction(
          title: "Переслать",
          image: UIImage(systemName: "arrowshape.turn.up.right"),
          identifier: MessengerAccessibility.Action.messageForward
        ) { [weak self] _ in
          self?.openForwardPicker(for: [message.id])
        }
      )

      actions.append(
        UIAction(title: "Выбрать сообщения", image: UIImage(systemName: "checklist")) { [weak self] _ in
          self?.enterSelectionMode(preselectedMessageId: message.id)
        }
      )
    }

    if viewModel.canEditMessage(message), message.deletedAt == nil {
      actions.append(
        UIAction(
          title: "Редактировать",
          image: UIImage(systemName: "pencil"),
          identifier: MessengerAccessibility.Action.messageEdit
        ) { [weak self] _ in
          guard let self else {
            return
          }

          self.showInputAlert(title: "Редактировать сообщение", placeholder: "Новый текст") { value in
            Task {
              do {
                try await self.viewModel.editMessage(messageId: message.id, content: value)
              } catch {
                self.showErrorAlert(message: error.localizedDescription)
              }
            }
          }
        }
      )
    }

    let historyAttributes: UIMenuElement.Attributes = viewModel.hasEdits(messageId: message.id) ? [] : [.disabled]
    let historyAction = UIAction(
      title: "История правок",
      image: UIImage(systemName: "clock.arrow.circlepath"),
      identifier: nil,
      discoverabilityTitle: nil,
      attributes: historyAttributes,
      state: .off
    ) { [weak self] _ in
      guard let self else {
        return
      }

      Task {
        let edits: [MessageEdit] = (try? await self.viewModel.listEdits(messageId: message.id)) ?? []
        let text: String = edits
          .map { edit in
            let date = Self.historyDateFormatter.string(from: edit.editedAt)
            return "\(date) — \(edit.oldContent.prefix(70))"
          }
          .joined(separator: "\n")

        self.showErrorAlert(message: text.isEmpty ? "Нет истории" : text, title: "История правок")
      }
    }
    actions.append(historyAction)

    if message.deletedAt == nil {
      if viewModel.isMessagePinned(message.id) {
        actions.append(
          UIAction(
            title: "Открепить",
            image: UIImage(systemName: "pin.slash"),
            identifier: MessengerAccessibility.Action.messageUnpin
          ) { [weak self] _ in
            guard let self,
              let pinnedMessage: PinnedMessage = self.viewModel.pinnedMessageRecord(messageId: message.id)
            else {
              return
            }

            self.presentPinnedUnpinOptions(for: pinnedMessage)
          }
        )
      } else {
        actions.append(
          UIAction(
            title: "Закрепить",
            image: UIImage(systemName: "pin"),
            identifier: MessengerAccessibility.Action.messagePin
          ) { [weak self] _ in
            Task {
              do {
                try await self?.viewModel.pinMessage(messageId: message.id)
              } catch {
                self?.showErrorAlert(message: error.localizedDescription)
              }
            }
          }
        )
      }
    }

    if viewModel.canManuallyMarkRead(message) {
      actions.append(
        UIAction(
          title: "Отметить прочитанным",
          image: UIImage(systemName: "checkmark.circle"),
          identifier: MessengerAccessibility.Action.messageMarkRead
        ) { [weak self] _ in
          Task {
            do {
              try await self?.viewModel.markAsRead(messageId: message.id)
            } catch {
              self?.showErrorAlert(message: error.localizedDescription)
            }
          }
        }
      )
    }

    actions.append(
      UIAction(
        title: "Удалить у меня",
        image: UIImage(systemName: "trash"),
        identifier: MessengerAccessibility.Action.messageDeleteForMe,
        attributes: .destructive
      ) { [weak self] _ in
        Task {
          do {
            try await self?.viewModel.deleteMessageForMe(messageId: message.id)
          } catch {
            self?.showErrorAlert(message: error.localizedDescription)
          }
        }
      }
    )

    if viewModel.isOutgoing(message), message.deletedAt == nil {
      actions.append(
        UIAction(
          title: "Удалить у всех",
          image: UIImage(systemName: "trash.slash"),
          identifier: MessengerAccessibility.Action.messageDeleteForAll,
          attributes: .destructive
        ) { [weak self] _ in
          Task {
            do {
              try await self?.viewModel.deleteMessage(messageId: message.id)
            } catch {
              self?.showErrorAlert(message: error.localizedDescription)
            }
          }
        }
      )
    }

    return actions
  }

  private static let messageTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private static let historyDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return formatter
  }()
}

extension ConversationViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    displayedMessages.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as? ConversationMessageCell else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    let message: Message = displayedMessages[indexPath.row]
    let viewData: MessageViewData = buildMessageViewData(message)
    let showReactionBar: Bool = !tableView.isEditing && reactionPickerMessageId == message.id
    let isHighlighted: Bool = highlightedMessageId == message.id
    let moreActionsMenu: UIMenu = UIMenu(title: "", children: contextActions(for: message, includeReactionMenu: false))

    cell.configure(
      viewData: viewData,
      isHighlighted: isHighlighted,
      showReactionBar: showReactionBar,
      emojis: viewData.isDeleted ? [] : reactionEmojis,
      moreActionsMenu: moreActionsMenu
    )
    cell.accessibilityIdentifier = MessengerAccessibility.View.messageCell(message.id)
    cell.onReactionSelected = { [weak self] emoji in
      guard let self else {
        return
      }

      Task {
        do {
          try await self.viewModel.toggleReaction(messageId: message.id, emoji: emoji)
        } catch {
          self.showErrorAlert(message: error.localizedDescription)
        }
        self.setReactionPickerMessageId(nil)
      }
    }

    cell.selectionStyle = .default
    cell.backgroundView = nil
    cell.selectedBackgroundView = nil
    return cell
  }
}

extension ConversationViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let message: Message = displayedMessages[indexPath.row]

    if tableView.isEditing {
      selectedMessageIds.insert(message.id)
      updateSelectionNavigationState()
      return
    }

    tableView.deselectRow(at: indexPath, animated: true)
    dismissReactionPicker()

    if message.deletedAt == nil, message.attachment != nil {
      openAttachmentPreview(for: message)
      return
    }
  }

  func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
    guard tableView.isEditing else {
      return
    }

    let message: Message = displayedMessages[indexPath.row]
    selectedMessageIds.remove(message.id)
    updateSelectionNavigationState()
  }

  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    nil
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    dismissReactionPicker()
    clearPinnedBannerSelectionOverride()
    updatePinnedMessageBanner()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if scrollView.contentOffset.y < -80 {
      Task {
        try? await viewModel.loadMoreMessages()
      }
    }

    updatePinnedMessageBanner()
    updateScrollToBottomButtonVisibility()
  }
}

extension ConversationViewController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let fileURL: URL = urls.first else {
      return
    }

    let pickedDocument: PickedDocument
    do {
      pickedDocument = try readPickedDocument(from: fileURL)
    } catch {
      showErrorAlert(message: "Не удалось прочитать вложение")
      return
    }

    Task {
      do {
        try await sendPickedAttachment(
          data: pickedDocument.data,
          fileName: pickedDocument.fileName,
          mimeType: pickedDocument.mimeType,
          type: pickedDocument.type
        )
      } catch let error as AttachmentInspectionError {
        switch error {
        case .warningRequiresAcknowledgement(let result):
          presentAttachmentWarning(
            title: "Рискованное вложение",
            message: result.summary,
            confirmTitle: "Отправить"
          ) { [weak self] in
            Task {
              do {
                try await self?.sendPickedAttachment(
                  data: pickedDocument.data,
                  fileName: pickedDocument.fileName,
                  mimeType: pickedDocument.mimeType,
                  type: pickedDocument.type,
                  allowRiskyUpload: true
                )
              } catch {
                self?.showErrorAlert(message: error.localizedDescription)
              }
            }
          }
        default:
          showErrorAlert(message: error.localizedDescription)
        }
      } catch {
        showErrorAlert(message: "Не удалось отправить вложение")
      }
    }
  }

  private func sendPickedAttachment(
    data: Data,
    fileName: String,
    mimeType: String,
    type: Message.MessageType,
    allowRiskyUpload: Bool = false
  ) async throws {
    _ = try await viewModel.sendAttachment(
      data: data,
      fileName: fileName,
      mimeType: mimeType,
      type: type,
      allowRiskyUpload: allowRiskyUpload
    )
  }

  private func readPickedDocument(from url: URL) throws -> PickedDocument {
    let startedAccessing: Bool = url.startAccessingSecurityScopedResource()
    defer {
      if startedAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let coordinator = NSFileCoordinator()
    var coordinatorError: NSError?
    var selectedData: Data?
    var selectedURL: URL = url
    var readError: Error?

    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinatedURL in
      do {
        selectedURL = coordinatedURL
        selectedData = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
      } catch {
        readError = error
      }
    }

    if let coordinatorError {
      throw coordinatorError
    }

    if let readError {
      throw readError
    }

    guard let selectedData else {
      throw CocoaError(.fileReadUnknown)
    }

    let fileName: String = preferredDocumentName(for: selectedURL)
    let mimeType: String = mimeTypeForFile(url: selectedURL)
    let type: Message.MessageType = mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") ? .media : .file

    return PickedDocument(
      data: selectedData,
      fileName: fileName,
      mimeType: mimeType,
      type: type
    )
  }

  private func preferredDocumentName(for url: URL) -> String {
    let values = try? url.resourceValues(forKeys: [.localizedNameKey, .nameKey])
    if let localizedName: String = values?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !localizedName.isEmpty
    {
      return localizedName
    }

    if let name: String = values?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    {
      return name
    }

    let fallbackName: String = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return fallbackName.isEmpty ? "attachment.bin" : fallbackName
  }

  private func mimeTypeForFile(url: URL) -> String {
    if let contentType: UTType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
      let mimeType: String = contentType.preferredMIMEType
    {
      return mimeType
    }

    if let fallbackType: UTType = UTType(filenameExtension: url.pathExtension),
      let mimeType: String = fallbackType.preferredMIMEType
    {
      return mimeType
    }

    return "application/octet-stream"
  }
}

extension ConversationViewController: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewedAttachment == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    let url: URL = previewedAttachment?.fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return url as NSURL
  }
}

extension ConversationViewController: QLPreviewControllerDelegate {
  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    clearPreviewedAttachmentState()
  }

  func previewController(
    _ controller: QLPreviewController,
    frameFor item: QLPreviewItem,
    inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>
  ) -> CGRect {
    guard let messageId: String = previewedAttachmentSourceMessageId,
      let sourceView: UIView = sourceBubbleView(for: messageId)
    else {
      view.pointee = nil
      return .zero
    }

    view.pointee = sourceView
    return sourceView.bounds
  }

  func previewController(_ controller: QLPreviewController, transitionViewFor item: QLPreviewItem) -> UIView? {
    guard let messageId: String = previewedAttachmentSourceMessageId else {
      return nil
    }

    return sourceBubbleView(for: messageId)
  }
}

private struct PickedDocument {
  let data: Data
  let fileName: String
  let mimeType: String
  let type: Message.MessageType
}

private final class ConversationMessageCell: UITableViewCell {
  private let bubbleView: UIView = UIView()
  private let stackView: UIStackView = UIStackView()
  private let forwardedLabel: UILabel = UILabel()
  private let replyLabel: UILabel = UILabel()
  private let messageLabel: UILabel = UILabel()
  private let reactionsLabel: UILabel = UILabel()
  private let reactionBar: UIStackView = UIStackView()
  private let footerLabel: UILabel = UILabel()

  private var bubbleLeadingPinned: NSLayoutConstraint?
  private var bubbleTrailingPinned: NSLayoutConstraint?
  private var bubbleLeadingLimit: NSLayoutConstraint?
  private var bubbleTrailingLimit: NSLayoutConstraint?
  private var reactionOptions: [String] = []
  private var isBubbleHighlighted: Bool = false

  var onReactionSelected: ((String) -> Void)?
  var previewTransitionView: UIView {
    bubbleView
  }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    configureLayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onReactionSelected = nil
    isBubbleHighlighted = false

    for view in reactionBar.arrangedSubviews {
      reactionBar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func configureLayout() {
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    bubbleView.translatesAutoresizingMaskIntoConstraints = false
    bubbleView.layer.cornerRadius = 14
    bubbleView.layer.borderWidth = 1
    bubbleView.layer.shadowOpacity = 0

    stackView.axis = .vertical
    stackView.spacing = 6
    stackView.translatesAutoresizingMaskIntoConstraints = false

    forwardedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    forwardedLabel.textColor = TelegramStyle.accentColor
    forwardedLabel.numberOfLines = 1

    replyLabel.font = .systemFont(ofSize: 11, weight: .medium)
    replyLabel.textColor = TelegramStyle.textSecondaryColor
    replyLabel.numberOfLines = 2

    messageLabel.font = .systemFont(ofSize: 15)
    messageLabel.textColor = TelegramStyle.textPrimaryColor
    messageLabel.numberOfLines = 0

    reactionsLabel.font = .systemFont(ofSize: 12, weight: .medium)
    reactionsLabel.textColor = TelegramStyle.textSecondaryColor
    reactionsLabel.numberOfLines = 1

    reactionBar.axis = .horizontal
    reactionBar.spacing = 6
    reactionBar.alignment = .leading
    reactionBar.distribution = .fillProportionally

    footerLabel.font = .systemFont(ofSize: 10, weight: .regular)
    footerLabel.textColor = TelegramStyle.textSecondaryColor
    footerLabel.numberOfLines = 1

    stackView.addArrangedSubview(forwardedLabel)
    stackView.addArrangedSubview(replyLabel)
    stackView.addArrangedSubview(messageLabel)
    stackView.addArrangedSubview(reactionsLabel)
    stackView.addArrangedSubview(reactionBar)
    stackView.addArrangedSubview(footerLabel)

    bubbleView.addSubview(stackView)
    contentView.addSubview(bubbleView)

    bubbleLeadingPinned = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
    bubbleTrailingPinned = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
    bubbleLeadingLimit = bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 70)
    bubbleTrailingLimit = bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -70)

    NSLayoutConstraint.activate([
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
      bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

      stackView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
      stackView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
      stackView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
      stackView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
    ])

    bubbleLeadingPinned?.isActive = true
    bubbleTrailingLimit?.isActive = true
  }

  func configure(
    viewData: ConversationViewController.MessageViewData,
    isHighlighted: Bool,
    showReactionBar: Bool,
    emojis: [String],
    moreActionsMenu: UIMenu?
  ) {
    if viewData.isOutgoing {
      bubbleLeadingPinned?.isActive = false
      bubbleTrailingLimit?.isActive = false
      bubbleLeadingLimit?.isActive = true
      bubbleTrailingPinned?.isActive = true
    } else {
      bubbleLeadingLimit?.isActive = false
      bubbleTrailingPinned?.isActive = false
      bubbleLeadingPinned?.isActive = true
      bubbleTrailingLimit?.isActive = true
    }

    applyBubbleAppearance(isOutgoing: viewData.isOutgoing, isHighlighted: isHighlighted, animated: isBubbleHighlighted != isHighlighted)
    isBubbleHighlighted = isHighlighted

    forwardedLabel.text = viewData.forwardedText
    forwardedLabel.isHidden = !viewData.isForwarded

    if let replyPreview: String = viewData.replyPreview {
      replyLabel.text = "↪︎ \(replyPreview)"
      replyLabel.isHidden = false
    } else {
      replyLabel.text = nil
      replyLabel.isHidden = true
    }

    if viewData.showEdited && !viewData.isDeleted {
      messageLabel.text = "\(viewData.text)\n(изменено)"
    } else {
      messageLabel.text = viewData.text
    }

    reactionsLabel.text = viewData.reactionsSummary
    reactionsLabel.isHidden = viewData.reactionsSummary == nil

    footerLabel.text = viewData.footer

    for view in reactionBar.arrangedSubviews {
      reactionBar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    reactionOptions = emojis
    if showReactionBar {
      for (index, emoji) in emojis.enumerated() {
        let button: UIButton = UIButton(type: .system)
        button.setTitle(emoji, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.backgroundColor = TelegramStyle.surfaceElevatedColor.withAlphaComponent(0.7)
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 1
        button.layer.borderColor = TelegramStyle.borderColor.cgColor
        button.tag = index
        button.addTarget(self, action: #selector(reactionTapped(_:)), for: .touchUpInside)
        button.accessibilityIdentifier = "\(MessengerAccessibility.Action.messageReact.rawValue).\(index)"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        reactionBar.addArrangedSubview(button)
      }

      if let moreActionsMenu {
        let moreButton: UIButton = UIButton(type: .system)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = TelegramStyle.textPrimaryColor
        moreButton.backgroundColor = TelegramStyle.surfaceElevatedColor.withAlphaComponent(0.7)
        moreButton.layer.cornerRadius = 12
        moreButton.layer.borderWidth = 1
        moreButton.layer.borderColor = TelegramStyle.borderColor.cgColor
        moreButton.menu = moreActionsMenu
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "Действия сообщения"
        moreButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        reactionBar.addArrangedSubview(moreButton)
      }
    }

    reactionBar.isHidden = !showReactionBar
  }

  func flashHighlight() {
    guard isBubbleHighlighted else {
      return
    }

    bubbleView.layer.removeAnimation(forKey: "message-highlight-pulse")
    let animation = CABasicAnimation(keyPath: "shadowOpacity")
    animation.fromValue = 0.18
    animation.toValue = 1.0
    animation.duration = 0.36
    animation.autoreverses = true
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    bubbleView.layer.add(animation, forKey: "message-highlight-pulse")
  }

  private func applyBubbleAppearance(isOutgoing: Bool, isHighlighted: Bool, animated: Bool) {
    let backgroundColor: UIColor
    let borderColor: UIColor
    let shadowColor: UIColor
    let shadowOpacity: Float
    let shadowRadius: CGFloat
    let shadowOffset: CGSize

    if isHighlighted {
      backgroundColor = TelegramStyle.accentColor.withAlphaComponent(isOutgoing ? 0.36 : 0.24)
      borderColor = TelegramStyle.accentColor.withAlphaComponent(0.92)
      shadowColor = TelegramStyle.accentColor.withAlphaComponent(0.75)
      shadowOpacity = 0.95
      shadowRadius = 18
      shadowOffset = CGSize(width: 0, height: 8)
    } else if isOutgoing {
      backgroundColor = TelegramStyle.accentColor.withAlphaComponent(0.24)
      borderColor = TelegramStyle.accentColor.withAlphaComponent(0.4)
      shadowColor = UIColor.clear
      shadowOpacity = 0
      shadowRadius = 0
      shadowOffset = .zero
    } else {
      backgroundColor = TelegramStyle.surfaceColor.withAlphaComponent(0.8)
      borderColor = TelegramStyle.borderColor
      shadowColor = UIColor.clear
      shadowOpacity = 0
      shadowRadius = 0
      shadowOffset = .zero
    }

    let updates = {
      self.bubbleView.backgroundColor = backgroundColor
      self.bubbleView.layer.borderColor = borderColor.cgColor
      self.bubbleView.layer.shadowColor = shadowColor.cgColor
      self.bubbleView.layer.shadowOpacity = shadowOpacity
      self.bubbleView.layer.shadowRadius = shadowRadius
      self.bubbleView.layer.shadowOffset = shadowOffset
    }

    if animated {
      UIView.animate(withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: updates)
    } else {
      updates()
    }
  }

  @objc
  private func reactionTapped(_ sender: UIButton) {
    let index: Int = sender.tag
    guard index >= 0, index < reactionOptions.count else {
      return
    }

    onReactionSelected?(reactionOptions[index])
  }
}

@MainActor
private final class ForwardConversationPickerViewController: UIViewController {
  var onConversationSelected: ((Conversation) -> Void)?

  private let viewModel: ChatsViewModel
  private let tableView: UITableView = UITableView(frame: .zero, style: .insetGrouped)

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

    title = "Кому переслать"
    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "forward-chat")
    TelegramStyle.styleTableView(tableView)

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    Task {
      do {
        try await viewModel.loadConversations()
        tableView.reloadData()
      } catch {
        showErrorAlert(message: error.localizedDescription)
      }
    }
  }
}

extension ForwardConversationPickerViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    viewModel.filteredConversations.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: "forward-chat", for: indexPath)
    let conversation: Conversation = viewModel.filteredConversations[indexPath.row]

    var content: UIListContentConfiguration = cell.defaultContentConfiguration()
    content.text = viewModel.title(for: conversation, currentUserId: viewModel.currentUserId)
    content.secondaryText = conversation.type == .direct ? "Личный чат" : "Группа"
    content.textProperties.color = TelegramStyle.textPrimaryColor
    content.secondaryTextProperties.color = TelegramStyle.textSecondaryColor
    content.image = UIImage(systemName: conversation.type == .group ? "person.3.fill" : "person.fill")
    content.imageProperties.tintColor = TelegramStyle.accentColor

    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    TelegramStyle.styleListCell(cell)
    return cell
  }
}

extension ForwardConversationPickerViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let conversation: Conversation = viewModel.filteredConversations[indexPath.row]
    onConversationSelected?(conversation)
    navigationController?.popViewController(animated: true)
  }
}
