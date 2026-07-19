import SwiftUI
import UIKit

struct ConversationScrollToBottomButtonView: View {
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Image(systemName: "arrow.down")
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(Color(uiColor: TelegramStyle.textPrimaryColor))
        .frame(width: 54, height: 54)
        .modifier(ScrollToBottomSurfaceModifier())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(MessengerAccessibility.Button.conversationScrollToBottom)
    .accessibilityLabel("Перейти вниз чата")
  }
}

private struct ScrollToBottomSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content
        .glassEffect(
          .regular
            .tint(Color(uiColor: TelegramStyle.surfaceElevatedColor).opacity(0.34))
            .interactive(),
          in: .circle
        )
    } else {
      content
        .background(.ultraThinMaterial, in: Circle())
        .overlay(
          Circle().stroke(Color(uiColor: TelegramStyle.borderColor), lineWidth: 1)
        )
        .shadow(color: Color(uiColor: TelegramStyle.accentColor).opacity(0.22), radius: 14, y: 8)
    }
  }
}
