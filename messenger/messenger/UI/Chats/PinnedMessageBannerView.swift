import UIKit
import SwiftUI

// Banner state is value-based so pin updates can be diffed without retaining table-view cells.
struct PinnedMessageBannerState: Equatable {
  let messageId: String
  let previewText: String
  let additionalPinnedCount: Int
  let showsDismissButton: Bool
}

struct PinnedMessageBannerView: View {
  let state: PinnedMessageBannerState?
  let onPrimaryTap: (String) -> Void
  let onSecondaryTap: (String) -> Void
  let onDismissTap: (String) -> Void

  var body: some View {
    Group {
      if let state {
        bannerContent(for: state)
      } else {
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 12)
    .padding(.top, 4)
    .padding(.bottom, 6)
    .background(Color.clear)
  }

  @ViewBuilder
  private func bannerContent(for state: PinnedMessageBannerState) -> some View {
    if #available(iOS 26, *) {
      GlassEffectContainer(spacing: 12) {
        contentStack(for: state)
      }
    } else {
      contentStack(for: state)
    }
  }

  private func contentStack(for state: PinnedMessageBannerState) -> some View {
    VStack(spacing: 10) {
      bannerSurface(for: state)

      if state.showsDismissButton {
        dismissButton(for: state)
      }
    }
  }

  private func bannerSurface(for state: PinnedMessageBannerState) -> some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    return HStack(spacing: 10) {
      Image(systemName: "pin.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color(uiColor: TelegramStyle.accentColor))

      Text(state.previewText)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color(uiColor: TelegramStyle.textPrimaryColor))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)

      if state.additionalPinnedCount > 0 {
        additionalPinsBadge(count: state.additionalPinnedCount)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)
    .modifier(PinnedBannerSurfaceModifier(shape: shape))
    .contentShape(shape)
    .highPriorityGesture(
      TapGesture(count: 2)
        .onEnded {
          onSecondaryTap(state.messageId)
        }
    )
    .onTapGesture {
      onPrimaryTap(state.messageId)
    }
    .onLongPressGesture(minimumDuration: 0.45) {
      onSecondaryTap(state.messageId)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(MessengerAccessibility.View.conversationPinnedBanner)
    .accessibilityLabel("Закреплённое сообщение. \(state.previewText)")
    .accessibilityHint(
      state.showsDismissButton
        ? "Открывает варианты открепления сообщения."
        : "Открывает закреплённое сообщение в чате."
    )
    .accessibilityAddTraits(.isButton)
  }

  private func dismissButton(for state: PinnedMessageBannerState) -> some View {
    HStack {
      Spacer(minLength: 0)

      Button {
        onDismissTap(state.messageId)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(Color(uiColor: TelegramStyle.textPrimaryColor))
          .frame(width: 38, height: 38)
      }
      .modifier(PinnedDismissButtonModifier())
      .accessibilityIdentifier(MessengerAccessibility.Button.conversationPinnedUnpin)
      .accessibilityLabel("Открепить сообщение")

      Spacer(minLength: 0)
    }
  }

  private func additionalPinsBadge(count: Int) -> some View {
    Text("+\(count)")
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(Color(uiColor: TelegramStyle.textPrimaryColor))
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .modifier(PinnedBannerBadgeModifier())
  }
}

private struct PinnedBannerSurfaceModifier<S: InsettableShape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content
        .glassEffect(
          .regular
            .tint(Color(uiColor: TelegramStyle.surfaceColor).opacity(0.32))
            .interactive(),
          in: .rect(cornerRadius: 22)
        )
    } else {
      content
        .background(.ultraThinMaterial, in: shape)
        .overlay(
          shape.stroke(Color(uiColor: TelegramStyle.borderColor), lineWidth: 1)
        )
        .shadow(color: Color(uiColor: TelegramStyle.accentColor).opacity(0.22), radius: 14, y: 8)
    }
  }
}

private struct PinnedDismissButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content.buttonStyle(.glassProminent)
    } else {
      content
        .background(.ultraThinMaterial, in: Circle())
        .overlay(
          Circle().stroke(Color(uiColor: TelegramStyle.borderColor), lineWidth: 1)
        )
    }
  }
}

private struct PinnedBannerBadgeModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content
        .glassEffect(
          .regular
            .tint(Color(uiColor: TelegramStyle.surfaceElevatedColor).opacity(0.28)),
          in: .capsule
        )
    } else {
      content
        .background(Color(uiColor: TelegramStyle.surfaceElevatedColor).opacity(0.82), in: Capsule())
        .overlay(
          Capsule().stroke(Color(uiColor: TelegramStyle.borderColor), lineWidth: 1)
        )
    }
  }
}
