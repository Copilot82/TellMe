import UIKit

enum TelegramStyle {
  static let accentColor: UIColor = UIColor(red: 0.22, green: 0.86, blue: 1.00, alpha: 1)
  static let accentSecondary: UIColor = UIColor(red: 0.49, green: 0.55, blue: 1.00, alpha: 1)
  static let groupedBackground: UIColor = UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)
  static let surfaceColor: UIColor = UIColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 0.64)
  static let surfaceElevatedColor: UIColor = UIColor(red: 0.12, green: 0.15, blue: 0.20, alpha: 0.82)
  static let textPrimaryColor: UIColor = UIColor(white: 0.96, alpha: 1)
  static let textSecondaryColor: UIColor = UIColor(white: 0.70, alpha: 1)
  static let borderColor: UIColor = UIColor.white.withAlphaComponent(0.14)
  static let warningColor: UIColor = UIColor(red: 1.00, green: 0.77, blue: 0.35, alpha: 1)
  static let destructiveColor: UIColor = UIColor(red: 1.00, green: 0.34, blue: 0.34, alpha: 1)

  private static let backgroundTag: Int = 9_821
  private static let glassTag: Int = 9_822
  private static var didApplyGlobalAppearance: Bool = false

  static func applyGlobalAppearance() {
    guard !didApplyGlobalAppearance else {
      return
    }

    didApplyGlobalAppearance = true

    UIView.appearance().tintColor = accentColor
    UILabel.appearance(whenContainedInInstancesOf: [UINavigationBar.self]).textColor = textPrimaryColor

    let navAppearance: UINavigationBarAppearance = UINavigationBarAppearance()
    navAppearance.configureWithTransparentBackground()
    navAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    navAppearance.backgroundColor = surfaceColor.withAlphaComponent(0.9)
    navAppearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
    navAppearance.titleTextAttributes = [
      .foregroundColor: textPrimaryColor,
      .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
    ]
    navAppearance.largeTitleTextAttributes = [
      .foregroundColor: textPrimaryColor,
      .font: UIFont.systemFont(ofSize: 32, weight: .bold),
    ]

    let navigationBar: UINavigationBar = UINavigationBar.appearance()
    navigationBar.standardAppearance = navAppearance
    navigationBar.scrollEdgeAppearance = navAppearance
    navigationBar.compactAppearance = navAppearance
    navigationBar.tintColor = accentColor

    let tabAppearance: UITabBarAppearance = UITabBarAppearance()
    tabAppearance.configureWithTransparentBackground()
    tabAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    tabAppearance.backgroundColor = surfaceColor.withAlphaComponent(0.94)
    tabAppearance.shadowColor = UIColor.white.withAlphaComponent(0.1)
    tabAppearance.stackedLayoutAppearance.normal.iconColor = textSecondaryColor
    tabAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: textSecondaryColor]
    tabAppearance.stackedLayoutAppearance.selected.iconColor = accentColor
    tabAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accentColor]

    let tabBar: UITabBar = UITabBar.appearance()
    tabBar.standardAppearance = tabAppearance
    tabBar.scrollEdgeAppearance = tabAppearance
    tabBar.unselectedItemTintColor = textSecondaryColor
    tabBar.tintColor = accentColor

    let segmentedControl: UISegmentedControl = UISegmentedControl.appearance()
    segmentedControl.backgroundColor = surfaceElevatedColor
    segmentedControl.selectedSegmentTintColor = accentColor.withAlphaComponent(0.25)
    segmentedControl.setTitleTextAttributes([
      .foregroundColor: textSecondaryColor,
      .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
    ], for: .normal)
    segmentedControl.setTitleTextAttributes([
      .foregroundColor: textPrimaryColor,
      .font: UIFont.systemFont(ofSize: 13, weight: .bold),
    ], for: .selected)

    UISwitch.appearance().onTintColor = accentColor
    UIRefreshControl.appearance().tintColor = accentColor
    UISearchBar.appearance().tintColor = accentColor

    let searchTextField: UITextField = UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])
    searchTextField.backgroundColor = surfaceColor.withAlphaComponent(0.78)
    searchTextField.textColor = textPrimaryColor
    searchTextField.attributedPlaceholder = NSAttributedString(
      string: "Поиск",
      attributes: [.foregroundColor: textSecondaryColor]
    )
    searchTextField.layer.cornerRadius = 10
    searchTextField.layer.borderWidth = 1
    searchTextField.layer.borderColor = borderColor.cgColor
  }

  @discardableResult
  static func installBackground(in view: UIView) -> UIView {
    if let existingBackground: UIView = view.viewWithTag(backgroundTag) {
      view.sendSubviewToBack(existingBackground)
      return existingBackground
    }

    let backgroundView: LiquidBackgroundView = LiquidBackgroundView()
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.tag = backgroundTag
    view.insertSubview(backgroundView, at: 0)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    return backgroundView
  }

  static func styleGlassCard(_ view: UIView, cornerRadius: CGFloat = 18) {
    view.backgroundColor = surfaceColor
    view.layer.cornerRadius = cornerRadius
    view.layer.borderColor = borderColor.cgColor
    view.layer.borderWidth = 1
    view.layer.shadowColor = accentColor.withAlphaComponent(0.25).cgColor
    view.layer.shadowOpacity = 1
    view.layer.shadowRadius = 18
    view.layer.shadowOffset = CGSize(width: 0, height: 10)

    if view.viewWithTag(glassTag) == nil {
      let blurView: UIVisualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
      blurView.tag = glassTag
      blurView.layer.cornerRadius = cornerRadius
      blurView.layer.masksToBounds = true
      blurView.translatesAutoresizingMaskIntoConstraints = false
      view.insertSubview(blurView, at: 0)

      NSLayoutConstraint.activate([
        blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        blurView.topAnchor.constraint(equalTo: view.topAnchor),
        blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
    }
  }

  static func styleTableView(_ tableView: UITableView) {
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.showsVerticalScrollIndicator = false
    tableView.sectionFooterHeight = .leastNormalMagnitude
    tableView.cellLayoutMarginsFollowReadableWidth = false

    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 8
    }
  }

  static func styleListCell(_ cell: UITableViewCell, cornerRadius: CGFloat = 14) {
    cell.backgroundColor = .clear
    cell.layoutMargins = .zero
    cell.contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

    let normalView: UIView = UIView()
    normalView.backgroundColor = surfaceColor.withAlphaComponent(0.72)
    normalView.layer.cornerRadius = cornerRadius
    normalView.layer.borderWidth = 1
    normalView.layer.borderColor = borderColor.cgColor
    cell.backgroundView = normalView

    let selectedView: UIView = UIView()
    selectedView.backgroundColor = accentColor.withAlphaComponent(0.18)
    selectedView.layer.cornerRadius = cornerRadius
    selectedView.layer.borderWidth = 1
    selectedView.layer.borderColor = accentColor.withAlphaComponent(0.4).cgColor
    cell.selectedBackgroundView = selectedView
  }

  static func styleMonospaceTextView(_ textView: UITextView) {
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textColor = textPrimaryColor
    textView.backgroundColor = surfaceColor.withAlphaComponent(0.82)
    textView.layer.cornerRadius = 12
    textView.layer.borderColor = borderColor.cgColor
    textView.layer.borderWidth = 1
  }

  static func makeTextField(placeholder: String) -> UITextField {
    let textField: UITextField = UITextField()
    textField.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: textSecondaryColor.withAlphaComponent(0.9)]
    )
    textField.borderStyle = .none
    textField.backgroundColor = surfaceColor.withAlphaComponent(0.78)
    textField.textColor = textPrimaryColor
    textField.tintColor = accentColor
    textField.layer.cornerRadius = 12
    textField.layer.borderColor = borderColor.cgColor
    textField.layer.borderWidth = 1
    textField.heightAnchor.constraint(equalToConstant: 44).isActive = true
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.clearButtonMode = .whileEditing
    textField.leftViewMode = .always
    textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    return textField
  }

  static func makePrimaryButton(title: String) -> UIButton {
    let button: UIButton = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.backgroundColor = accentColor
    button.layer.cornerRadius = 12
    button.layer.shadowColor = accentColor.withAlphaComponent(0.55).cgColor
    button.layer.shadowOpacity = 1
    button.layer.shadowOffset = CGSize(width: 0, height: 8)
    button.layer.shadowRadius = 18
    button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    return button
  }

  static func makeSecondaryButton(title: String) -> UIButton {
    let button: UIButton = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(textPrimaryColor, for: .normal)
    button.backgroundColor = surfaceColor.withAlphaComponent(0.75)
    button.layer.cornerRadius = 12
    button.layer.borderColor = borderColor.cgColor
    button.layer.borderWidth = 1
    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    return button
  }

  static func makeDestructiveButton(title: String) -> UIButton {
    let button: UIButton = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.backgroundColor = destructiveColor.withAlphaComponent(0.34)
    button.layer.cornerRadius = 12
    button.layer.borderColor = destructiveColor.withAlphaComponent(0.7).cgColor
    button.layer.borderWidth = 1
    button.layer.shadowColor = destructiveColor.withAlphaComponent(0.5).cgColor
    button.layer.shadowOpacity = 1
    button.layer.shadowOffset = CGSize(width: 0, height: 8)
    button.layer.shadowRadius = 18
    button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    button.heightAnchor.constraint(equalToConstant: 48).isActive = true
    return button
  }

  static func makeFloatingActionButton(symbolName: String) -> UIButton {
    let button: UIButton = UIButton(type: .system)
    button.setImage(UIImage(systemName: symbolName), for: .normal)
    button.tintColor = textPrimaryColor
    button.backgroundColor = accentColor.withAlphaComponent(0.88)
    button.layer.cornerRadius = 28
    button.layer.borderWidth = 1
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
    button.layer.shadowColor = accentColor.withAlphaComponent(0.55).cgColor
    button.layer.shadowOpacity = 1
    button.layer.shadowRadius = 16
    button.layer.shadowOffset = CGSize(width: 0, height: 10)
    button.widthAnchor.constraint(equalToConstant: 56).isActive = true
    button.heightAnchor.constraint(equalToConstant: 56).isActive = true
    return button
  }
}

private final class LiquidBackgroundView: UIView {
  private let gradientLayer: CAGradientLayer = CAGradientLayer()
  private let glowLayerTop: CAGradientLayer = CAGradientLayer()
  private let glowLayerBottom: CAGradientLayer = CAGradientLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    setupLayers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradientLayer.frame = bounds
    glowLayerTop.frame = bounds
    glowLayerBottom.frame = bounds
  }

  private func setupLayers() {
    gradientLayer.colors = [
      UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1).cgColor,
      UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor,
      UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1).cgColor,
    ]
    gradientLayer.locations = [0, 0.45, 1]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)

    glowLayerTop.type = .radial
    glowLayerTop.colors = [
      TelegramStyle.accentColor.withAlphaComponent(0.28).cgColor,
      UIColor.clear.cgColor,
    ]
    glowLayerTop.locations = [0, 1]
    glowLayerTop.startPoint = CGPoint(x: 0.2, y: 0.1)
    glowLayerTop.endPoint = CGPoint(x: 1, y: 1)

    glowLayerBottom.type = .radial
    glowLayerBottom.colors = [
      TelegramStyle.accentSecondary.withAlphaComponent(0.2).cgColor,
      UIColor.clear.cgColor,
    ]
    glowLayerBottom.locations = [0, 1]
    glowLayerBottom.startPoint = CGPoint(x: 0.8, y: 0.9)
    glowLayerBottom.endPoint = CGPoint(x: 1, y: 1)

    layer.addSublayer(gradientLayer)
    layer.addSublayer(glowLayerTop)
    layer.addSublayer(glowLayerBottom)
  }
}
