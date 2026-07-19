import UIKit

@MainActor
final class OnboardingViewController: UIViewController {
  private let pages: [OnboardingPage] = [
    OnboardingPage(
      symbolName: "bubble.left.and.bubble.right.fill",
      fallbackSymbolName: "message.fill",
      title: "TellMe - приватный мессенджер",
      body: "Общайтесь в чатах, отправляйте файлы и звоните так, чтобы содержимое оставалось доступно только вашим устройствам и устройствам собеседников."
    ),
    OnboardingPage(
      symbolName: "server.rack",
      fallbackSymbolName: "network",
      title: "Тестирование на отдельном сервере",
      body: "Тестовая версия TellMe подключена к серверу, выделенному для проверки мессенджера.",
      highlight: OnboardingHighlight(
        caption: "Тестовый сервер",
        value: TestServerConfiguration.domain,
        detail: "При регистрации укажите только login. Полный адрес будет создан в формате \(TestServerConfiguration.handleTemplate)."
      )
    ),
    OnboardingPage(
      symbolName: "key.fill",
      fallbackSymbolName: "lock.fill",
      title: "Регистрация создает seed phrase",
      body: "При создании аккаунта приложение сгенерирует recovery phrase. Сохраните ее отдельно: она восстанавливает ключи аккаунта и не хранится на сервере."
    ),
    OnboardingPage(
      symbolName: "qrcode.viewfinder",
      fallbackSymbolName: "qrcode",
      title: "Новое устройство нужно привязать",
      body: "Вход на другом телефоне выполняется через доверенное устройство. Откройте привязку, подтвердите запрос и получите защищенный доступ без передачи приватных ключей серверу."
    ),
    OnboardingPage(
      symbolName: "qrcode.viewfinder",
      fallbackSymbolName: "qrcode",
      title: "Добавьте друг друга",
      body: "Чтобы подтвердить защищенный контакт, выполните эти шаги на устройствах обоих собеседников. Порядок устройств не важен.",
      steps: [
        OnboardingStep(
          title: "Откройте добавление",
          body: "На главном экране нажмите круглую синюю кнопку."
        ),
        OnboardingStep(
          title: "Покажите или отсканируйте QR",
          body: "Выберите «Мой QR / код» или «Скан QR»."
        ),
        OnboardingStep(
          title: "Откройте чат",
          body: "После сканирования нажмите «Открыть чат»."
        ),
      ],
      notice: "Повторите действия на втором устройстве, поменявшись ролями. Взаимная проверка подтверждает ключи обоих собеседников и гарантирует, что защищенный чат связан именно с их устройствами."
    ),
    OnboardingPage(
      symbolName: "lock.shield.fill",
      fallbackSymbolName: "lock.fill",
      title: "Сервер доставляет, но не читает",
      body: "Сообщения, вложения и сигналинг звонков шифруются на устройстве. Сервер хранит маршрутизацию и ciphertext, но не ключи для чтения переписки."
    ),
  ]

  private let onFinish: () -> Void
  private let scrollView: UIScrollView = UIScrollView()
  private let pageStackView: UIStackView = UIStackView()
  private let pageControl: UIPageControl = UIPageControl()
  private let backButton: UIButton = TelegramStyle.makeSecondaryButton(title: "Назад")
  private let nextButton: UIButton = TelegramStyle.makePrimaryButton(title: "Далее")

  private var currentPageIndex: Int = 0
  private var pendingProgrammaticPageIndex: Int?
  private var lastLaidOutScrollWidth: CGFloat = 0

  init(onFinish: @escaping () -> Void) {
    self.onFinish = onFinish
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .clear
    TelegramStyle.installBackground(in: view)
    view.accessibilityIdentifier = MessengerAccessibility.Screen.onboarding

    configureScrollView()
    configureControls()
    layoutInterface()
    updateControls()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    let scrollWidth: CGFloat = scrollView.bounds.width
    guard scrollWidth > 0, abs(scrollWidth - lastLaidOutScrollWidth) > 0.5 else {
      return
    }

    lastLaidOutScrollWidth = scrollWidth
    scrollToPage(currentPageIndex, animated: false)
  }

  private func configureScrollView() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.delegate = self
    scrollView.isPagingEnabled = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    scrollView.alwaysBounceHorizontal = true
    scrollView.contentInsetAdjustmentBehavior = .never

    pageStackView.axis = .horizontal
    pageStackView.alignment = .fill
    pageStackView.distribution = .fill
    pageStackView.spacing = 0
    pageStackView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(pageStackView)

    for page in pages {
      let pageView = OnboardingPageView(page: page)
      pageStackView.addArrangedSubview(pageView)
      pageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
    }
  }

  private func configureControls() {
    pageControl.numberOfPages = pages.count
    pageControl.currentPage = 0
    pageControl.pageIndicatorTintColor = TelegramStyle.textSecondaryColor.withAlphaComponent(0.35)
    pageControl.currentPageIndicatorTintColor = TelegramStyle.accentColor
    pageControl.accessibilityIdentifier = MessengerAccessibility.View.onboardingPageControl
    pageControl.addTarget(self, action: #selector(pageControlChanged), for: .valueChanged)

    backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    backButton.accessibilityIdentifier = MessengerAccessibility.Button.onboardingBack

    nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
    nextButton.accessibilityIdentifier = MessengerAccessibility.Button.onboardingNext
  }

  private func layoutInterface() {
    let headerLabel: UILabel = UILabel()
    headerLabel.text = "TellMe"
    headerLabel.font = .systemFont(ofSize: 32, weight: .bold)
    headerLabel.textColor = TelegramStyle.textPrimaryColor
    headerLabel.textAlignment = .center
    headerLabel.adjustsFontForContentSizeCategory = true

    let controlsStackView: UIStackView = UIStackView(arrangedSubviews: [
      backButton,
      nextButton,
    ])
    controlsStackView.axis = .horizontal
    controlsStackView.spacing = 10
    controlsStackView.distribution = .fillEqually
    controlsStackView.translatesAutoresizingMaskIntoConstraints = false

    let rootStackView: UIStackView = UIStackView(arrangedSubviews: [
      headerLabel,
      scrollView,
      pageControl,
      controlsStackView,
    ])
    rootStackView.axis = .vertical
    rootStackView.spacing = 18
    rootStackView.translatesAutoresizingMaskIntoConstraints = false
    rootStackView.setCustomSpacing(10, after: pageControl)

    view.addSubview(rootStackView)

    let scrollMinHeight: NSLayoutConstraint = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
    scrollMinHeight.priority = .defaultLow

    NSLayoutConstraint.activate([
      rootStackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      rootStackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      rootStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
      rootStackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

      scrollMinHeight,

      pageStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      pageStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      pageStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      pageStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      pageStackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
  }

  private func updateControls() {
    pageControl.currentPage = currentPageIndex
    backButton.alpha = currentPageIndex == 0 ? 0 : 1
    backButton.isEnabled = currentPageIndex > 0
    backButton.accessibilityElementsHidden = currentPageIndex == 0
    let isLastPage: Bool = currentPageIndex == pages.count - 1
    nextButton.setTitle(isLastPage ? "К авторизации" : "Далее", for: .normal)
    nextButton.accessibilityIdentifier = isLastPage
      ? MessengerAccessibility.Button.onboardingFinish
      : MessengerAccessibility.Button.onboardingNext
  }

  private func setCurrentPage(_ index: Int, animated: Bool) {
    guard pages.indices.contains(index) else {
      return
    }

    currentPageIndex = index
    pendingProgrammaticPageIndex = animated ? index : nil
    updateControls()
    scrollToPage(index, animated: animated)
  }

  private func scrollToPage(_ index: Int, animated: Bool) {
    guard pages.indices.contains(index) else {
      return
    }

    let xOffset: CGFloat = CGFloat(index) * scrollView.bounds.width
    scrollView.setContentOffset(CGPoint(x: xOffset, y: 0), animated: animated)
  }

  private func visiblePageIndex() -> Int {
    guard scrollView.bounds.width > 0 else {
      return currentPageIndex
    }

    let rawIndex: CGFloat = scrollView.contentOffset.x / scrollView.bounds.width
    return min(max(Int(round(rawIndex)), 0), pages.count - 1)
  }

  private func updatePageIndexFromScrollPosition() {
    let resolvedIndex: Int = visiblePageIndex()
    guard resolvedIndex != currentPageIndex else {
      return
    }

    currentPageIndex = resolvedIndex
    updateControls()
  }

  @objc
  private func pageControlChanged() {
    setCurrentPage(pageControl.currentPage, animated: true)
  }

  @objc
  private func backTapped() {
    let visibleIndex: Int = pendingProgrammaticPageIndex ?? visiblePageIndex()
    setCurrentPage(max(visibleIndex - 1, 0), animated: true)
  }

  @objc
  private func nextTapped() {
    let visibleIndex: Int = pendingProgrammaticPageIndex ?? visiblePageIndex()
    guard visibleIndex < pages.count - 1 else {
      onFinish()
      return
    }

    setCurrentPage(visibleIndex + 1, animated: true)
  }
}

extension OnboardingViewController: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard pendingProgrammaticPageIndex == nil else {
      return
    }

    updatePageIndexFromScrollPosition()
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    updatePageIndexFromScrollPosition()
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    if let pendingProgrammaticPageIndex {
      self.pendingProgrammaticPageIndex = nil
      currentPageIndex = pendingProgrammaticPageIndex
      updateControls()
      return
    }

    updatePageIndexFromScrollPosition()
  }
}

private struct OnboardingPage {
  let symbolName: String
  let fallbackSymbolName: String
  let title: String
  let body: String
  let highlight: OnboardingHighlight?
  let steps: [OnboardingStep]
  let notice: String?

  init(
    symbolName: String,
    fallbackSymbolName: String,
    title: String,
    body: String,
    highlight: OnboardingHighlight? = nil,
    steps: [OnboardingStep] = [],
    notice: String? = nil
  ) {
    self.symbolName = symbolName
    self.fallbackSymbolName = fallbackSymbolName
    self.title = title
    self.body = body
    self.highlight = highlight
    self.steps = steps
    self.notice = notice
  }
}

private struct OnboardingHighlight {
  let caption: String
  let value: String
  let detail: String
}

private struct OnboardingStep {
  let title: String
  let body: String
}

private final class OnboardingPageView: UIView {
  init(page: OnboardingPage) {
    super.init(frame: .zero)
    configure(page: page)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configure(page: OnboardingPage) {
    let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
    let symbolImage = UIImage(systemName: page.symbolName, withConfiguration: symbolConfiguration)
      ?? UIImage(systemName: page.fallbackSymbolName, withConfiguration: symbolConfiguration)

    let imageView: UIImageView = UIImageView(image: symbolImage)
    imageView.tintColor = TelegramStyle.accentColor
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let iconContainer: UIView = UIView()
    iconContainer.backgroundColor = TelegramStyle.surfaceElevatedColor.withAlphaComponent(0.72)
    iconContainer.layer.cornerRadius = 36
    iconContainer.layer.borderWidth = 1
    iconContainer.layer.borderColor = TelegramStyle.borderColor.cgColor
    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.addSubview(imageView)

    let iconWrapper: UIView = UIView()
    iconWrapper.addSubview(iconContainer)

    let titleLabel: UILabel = UILabel()
    titleLabel.text = page.title
    titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
    titleLabel.textColor = TelegramStyle.textPrimaryColor
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    titleLabel.adjustsFontForContentSizeCategory = true

    let bodyLabel: UILabel = UILabel()
    bodyLabel.text = page.body
    bodyLabel.font = .systemFont(ofSize: 17, weight: .regular)
    bodyLabel.textColor = TelegramStyle.textSecondaryColor
    bodyLabel.textAlignment = .center
    bodyLabel.numberOfLines = 0
    bodyLabel.adjustsFontForContentSizeCategory = true

    var contentViews: [UIView] = [
      iconWrapper,
      titleLabel,
      bodyLabel,
    ]

    if let highlight: OnboardingHighlight = page.highlight {
      let highlightView: UIView = makeHighlightView(highlight)
      highlightView.accessibilityIdentifier = MessengerAccessibility.View.onboardingTestServer
      contentViews.append(highlightView)
    }

    if !page.steps.isEmpty {
      let stepsView: UIView = makeStepsView(page.steps)
      stepsView.accessibilityIdentifier = MessengerAccessibility.View.onboardingContactSteps
      contentViews.append(stepsView)
    }

    if let notice: String = page.notice {
      contentViews.append(makeNoticeView(text: notice))
    }

    let contentStackView: UIStackView = UIStackView(arrangedSubviews: contentViews)
    contentStackView.axis = .vertical
    contentStackView.alignment = .fill
    contentStackView.spacing = 16
    contentStackView.setCustomSpacing(22, after: iconWrapper)

    let topSpacer: UIView = UIView()
    let bottomSpacer: UIView = UIView()
    let centeringStackView: UIStackView = UIStackView(arrangedSubviews: [
      topSpacer,
      contentStackView,
      bottomSpacer,
    ])
    centeringStackView.axis = .vertical
    centeringStackView.spacing = 0
    centeringStackView.translatesAutoresizingMaskIntoConstraints = false

    let scrollView: UIScrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    scrollView.isDirectionalLockEnabled = true

    let contentView: UIView = UIView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentView)
    contentView.addSubview(centeringStackView)

    addSubview(scrollView)

    let equalSpacerHeights: NSLayoutConstraint = topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor)
    equalSpacerHeights.priority = .defaultHigh

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

      centeringStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      centeringStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      centeringStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
      centeringStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      topSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
      bottomSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
      equalSpacerHeights,

      iconContainer.widthAnchor.constraint(equalToConstant: 72),
      iconContainer.heightAnchor.constraint(equalToConstant: 72),
      iconContainer.centerXAnchor.constraint(equalTo: iconWrapper.centerXAnchor),
      iconContainer.topAnchor.constraint(equalTo: iconWrapper.topAnchor),
      iconContainer.bottomAnchor.constraint(equalTo: iconWrapper.bottomAnchor),

      imageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 42),
      imageView.heightAnchor.constraint(equalToConstant: 42),
    ])
  }

  private func makeHighlightView(_ highlight: OnboardingHighlight) -> UIView {
    let captionLabel: UILabel = UILabel()
    captionLabel.text = highlight.caption.uppercased()
    captionLabel.font = .systemFont(ofSize: 11, weight: .bold)
    captionLabel.textColor = TelegramStyle.accentColor

    let valueLabel: UILabel = UILabel()
    valueLabel.text = highlight.value
    valueLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
    valueLabel.textColor = TelegramStyle.textPrimaryColor
    valueLabel.adjustsFontSizeToFitWidth = true
    valueLabel.minimumScaleFactor = 0.75

    let detailLabel: UILabel = UILabel()
    detailLabel.text = highlight.detail
    detailLabel.font = .systemFont(ofSize: 14, weight: .regular)
    detailLabel.textColor = TelegramStyle.textSecondaryColor
    detailLabel.numberOfLines = 0

    let labelsStackView: UIStackView = UIStackView(arrangedSubviews: [
      captionLabel,
      valueLabel,
      detailLabel,
    ])
    labelsStackView.axis = .vertical
    labelsStackView.spacing = 6
    labelsStackView.translatesAutoresizingMaskIntoConstraints = false

    let serverImageView: UIImageView = UIImageView(image: UIImage(systemName: "network"))
    serverImageView.tintColor = TelegramStyle.accentColor
    serverImageView.contentMode = .scaleAspectFit
    serverImageView.translatesAutoresizingMaskIntoConstraints = false

    let highlightView: UIView = UIView()
    highlightView.backgroundColor = TelegramStyle.accentColor.withAlphaComponent(0.08)
    highlightView.layer.cornerRadius = 12
    highlightView.layer.borderWidth = 1
    highlightView.layer.borderColor = TelegramStyle.accentColor.withAlphaComponent(0.28).cgColor
    highlightView.addSubview(serverImageView)
    highlightView.addSubview(labelsStackView)

    NSLayoutConstraint.activate([
      serverImageView.leadingAnchor.constraint(equalTo: highlightView.leadingAnchor, constant: 14),
      serverImageView.topAnchor.constraint(equalTo: highlightView.topAnchor, constant: 16),
      serverImageView.widthAnchor.constraint(equalToConstant: 24),
      serverImageView.heightAnchor.constraint(equalToConstant: 24),

      labelsStackView.leadingAnchor.constraint(equalTo: serverImageView.trailingAnchor, constant: 12),
      labelsStackView.trailingAnchor.constraint(equalTo: highlightView.trailingAnchor, constant: -14),
      labelsStackView.topAnchor.constraint(equalTo: highlightView.topAnchor, constant: 14),
      labelsStackView.bottomAnchor.constraint(equalTo: highlightView.bottomAnchor, constant: -14),
    ])

    return highlightView
  }

  private func makeStepsView(_ steps: [OnboardingStep]) -> UIView {
    let stepsStackView: UIStackView = UIStackView()
    stepsStackView.axis = .vertical
    stepsStackView.spacing = 12

    for (index, step) in steps.enumerated() {
      let numberLabel: UILabel = UILabel()
      numberLabel.text = String(index + 1)
      numberLabel.font = .systemFont(ofSize: 14, weight: .bold)
      numberLabel.textColor = TelegramStyle.groupedBackground
      numberLabel.textAlignment = .center
      numberLabel.backgroundColor = TelegramStyle.accentColor
      numberLabel.layer.cornerRadius = 14
      numberLabel.clipsToBounds = true
      numberLabel.translatesAutoresizingMaskIntoConstraints = false

      let titleLabel: UILabel = UILabel()
      titleLabel.text = step.title
      titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
      titleLabel.textColor = TelegramStyle.textPrimaryColor
      titleLabel.numberOfLines = 0

      let bodyLabel: UILabel = UILabel()
      bodyLabel.text = step.body
      bodyLabel.font = .systemFont(ofSize: 13, weight: .regular)
      bodyLabel.textColor = TelegramStyle.textSecondaryColor
      bodyLabel.numberOfLines = 0

      let textStackView: UIStackView = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
      textStackView.axis = .vertical
      textStackView.spacing = 2

      let rowStackView: UIStackView = UIStackView(arrangedSubviews: [numberLabel, textStackView])
      rowStackView.axis = .horizontal
      rowStackView.alignment = .top
      rowStackView.spacing = 11
      stepsStackView.addArrangedSubview(rowStackView)

      NSLayoutConstraint.activate([
        numberLabel.widthAnchor.constraint(equalToConstant: 28),
        numberLabel.heightAnchor.constraint(equalToConstant: 28),
      ])
    }

    return stepsStackView
  }

  private func makeNoticeView(text: String) -> UIView {
    let imageView: UIImageView = UIImageView(image: UIImage(systemName: "checkmark.shield.fill"))
    imageView.tintColor = TelegramStyle.warningColor
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let label: UILabel = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = TelegramStyle.textPrimaryColor
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false

    let noticeView: UIView = UIView()
    noticeView.backgroundColor = TelegramStyle.warningColor.withAlphaComponent(0.09)
    noticeView.layer.cornerRadius = 12
    noticeView.layer.borderWidth = 1
    noticeView.layer.borderColor = TelegramStyle.warningColor.withAlphaComponent(0.3).cgColor
    noticeView.addSubview(imageView)
    noticeView.addSubview(label)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: noticeView.leadingAnchor, constant: 12),
      imageView.topAnchor.constraint(equalTo: noticeView.topAnchor, constant: 13),
      imageView.widthAnchor.constraint(equalToConstant: 22),
      imageView.heightAnchor.constraint(equalToConstant: 22),

      label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: noticeView.trailingAnchor, constant: -12),
      label.topAnchor.constraint(equalTo: noticeView.topAnchor, constant: 11),
      label.bottomAnchor.constraint(equalTo: noticeView.bottomAnchor, constant: -11),
    ])

    return noticeView
  }
}
