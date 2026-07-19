import UIKit

@MainActor
final class ChatsCoordinator: Coordinator {
  private let navigationController: UINavigationController
  private let container: AppContainer

  private var listViewModel: ChatsViewModel?
  var onCallPresentationRequested: (() -> Void)?

  init(navigationController: UINavigationController, container: AppContainer) {
    self.navigationController = navigationController
    self.container = container
  }

  deinit {
    Task { @MainActor in
      ActiveCallPresentationRouter.shared.cleanupReleasedPresenters()
    }
  }

  func start() {
    let viewModel: ChatsViewModel = ChatsViewModel(
      container: container,
      e2eSecurityService: container.e2eSecurityService,
      sessionStore: container.sessionStore,
      messageService: container.messageService,
      realtimeRouter: container.realtimeRouter,
      defaults: container.defaults,
      secureStateStore: container.secureStateStore,
      keyMaterialStore: container.keyMaterialStore,
      identityService: container.identityService
    )

    listViewModel = viewModel

    let controller: ChatsListViewController = ChatsListViewController(viewModel: viewModel)
    controller.onOpenConversation = { [weak self] conversation in
      self?.openConversation(conversation)
    }
    controller.onCreateConversation = { [weak self] in
      self?.openNewChat()
    }
    controller.onShowMyCode = { [weak self] in
      self?.openMyContactCode()
    }

    navigationController.setViewControllers([controller], animated: false)
    ActiveCallPresentationRouter.shared.register(self)
    drainAcceptedSystemCalls()
  }

  private func openNewChat() {
    guard let listViewModel else {
      return
    }

    let controller: NewChatViewController = NewChatViewController(viewModel: listViewModel)
    controller.onConversationReady = { [weak self] conversation in
      self?.navigationController.popViewController(animated: true)
      self?.openConversation(conversation)
    }

    navigationController.pushViewController(controller, animated: true)
  }

  private func openConversation(_ conversation: Conversation) {
    let conversationViewModel: ConversationViewModel = ConversationViewModel(
      container: container,
      conversation: conversation,
      defaults: container.defaults
    )
    let controller: ConversationViewController = ConversationViewController(viewModel: conversationViewModel)
    controller.onStartCall = { [weak self] viewModel, callType in
      self?.openOutgoingCall(conversationViewModel: viewModel, callType: callType)
    }
    controller.onAnswerCall = { [weak self] viewModel, offer, callType, callerUserId in
      self?.openIncomingCall(
        conversationViewModel: viewModel,
        offer: offer,
        callType: callType,
        callerUserId: callerUserId
      )
    }
    controller.hidesBottomBarWhenPushed = conversation.type == .direct

    navigationController.pushViewController(controller, animated: true)
  }

  private func openOutgoingCall(conversationViewModel: ConversationViewModel, callType: Call.CallType) {
    guard let peerUserId: String = conversationViewModel.peerUserId else {
      navigationController.topViewController?.showErrorAlert(message: "Не удалось определить получателя звонка.")
      return
    }

    let callId: String = UUID().uuidString.lowercased()
    let callViewModel = E2ECallSessionViewModel(
      conversationViewModel: conversationViewModel,
      role: .initiator,
      callId: callId,
      peerUserId: peerUserId,
      callType: callType
    )
    openCallScreen(viewModel: container.e2eCallSessionStore.retain(callViewModel))
  }

  private func openIncomingCall(
    conversationViewModel: ConversationViewModel,
    offer: CallSessionDescriptionSignal,
    callType: Call.CallType,
    callerUserId: String
  ) {
    let callViewModel = E2ECallSessionViewModel(
      conversationViewModel: conversationViewModel,
      role: .receiver(offer: offer),
      callId: offer.callId,
      peerUserId: callerUserId,
      callType: callType
    )
    openCallScreen(viewModel: container.e2eCallSessionStore.retain(callViewModel))
  }

  func openIncomingSystemCall(_ descriptor: E2EIncomingCallDescriptor) {
    let retainedCallViewModel: E2ECallSessionViewModel
    if let existing: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: descriptor.callId) {
      retainedCallViewModel = existing
    } else {
      let conversationViewModel = ConversationViewModel(
        container: container,
        conversation: descriptor.conversation,
        defaults: container.defaults
      )
      let callViewModel = E2ECallSessionViewModel(
        conversationViewModel: conversationViewModel,
        role: .receiver(offer: descriptor.offer),
        callId: descriptor.callId,
        peerUserId: descriptor.callerUserId,
        callType: descriptor.callType
      )
      retainedCallViewModel = container.e2eCallSessionStore.retain(callViewModel)
    }
    // SystemCallCoordinator starts accepted media even with no foreground UI.
    // This idempotent call also covers legacy/in-app delivery paths.
    retainedCallViewModel.start()
    openCallScreen(viewModel: retainedCallViewModel, shouldAutoStart: false)
  }

  func openCallScreen(
    viewModel: E2ECallSessionViewModel,
    animated: Bool = true,
    shouldAutoStart: Bool = true,
    completion: ((Bool) -> Void)? = nil
  ) {
    onCallPresentationRequested?()

    if let existing = navigationController.viewControllers.compactMap({ $0 as? E2ECallViewController })
      .first(where: { $0.activeCallId == viewModel.activeCallId })
    {
      navigationController.popToViewController(existing, animated: animated)
      completion?(true)
      return
    }

    if navigationController.topViewController is E2ECallViewController {
      completion?(false)
      return
    }

    let controller: E2ECallViewController = E2ECallViewController(
      viewModel: viewModel,
      shouldAutoStart: shouldAutoStart
    )
    controller.hidesBottomBarWhenPushed = true
    if animated {
      CATransaction.begin()
      CATransaction.setCompletionBlock {
        completion?(true)
      }
      navigationController.pushViewController(controller, animated: true)
      CATransaction.commit()
    } else {
      navigationController.pushViewController(controller, animated: false)
      completion?(true)
    }
  }

  private func drainAcceptedSystemCalls() {
    for descriptor in container.systemCallCoordinator.takeAcceptedIncomingCalls() {
      openIncomingSystemCall(descriptor)
    }
  }

  func restoreActiveCallInterface(
    callId: String,
    animated: Bool = true,
    completion: ((Bool) -> Void)?
  ) {
    guard let session: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: callId) else {
      completion?(false)
      return
    }

    openCallScreen(
      viewModel: session,
      animated: animated,
      shouldAutoStart: false,
      completion: completion
    )
  }

#if DEBUG
  func restoreActiveCallInterfaceForTesting(
    callId: String,
    animated: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard let session: E2ECallSessionViewModel = container.e2eCallSessionStore.session(callId: callId) else {
      completion?(false)
      return
    }

    openCallScreen(
      viewModel: session,
      animated: animated,
      shouldAutoStart: false,
      completion: completion
    )
  }
#endif

  private func openMyContactCode() {
    guard let listViewModel else {
      return
    }

    do {
      let shareData: ChatsViewModel.ContactShareData = try listViewModel.myContactShareData()
      let controller: ContactShareViewController = ContactShareViewController(shareData: shareData)
      navigationController.pushViewController(controller, animated: true)
    } catch {
      navigationController.topViewController?.showErrorAlert(message: "Не удалось подготовить ваш QR/код. Выполните вход заново.")
    }
  }
}

extension ChatsCoordinator: ActiveCallPresenting {
  var activeCallPresentationScene: UIWindowScene? {
    navigationController.view.window?.windowScene
  }

  func presentAcceptedIncomingCall(_ descriptor: E2EIncomingCallDescriptor) {
    openIncomingSystemCall(descriptor)
  }
}
