import Foundation

enum UserHandleDisplay {
  static func usernameOnly(from rawValue: String) -> String {
    let trimmed: String = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return rawValue
    }

    let withoutAt: String = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    guard let separatorIndex: String.Index = withoutAt.firstIndex(of: ":") else {
      return withoutAt
    }

    let username: String = String(withoutAt[..<separatorIndex])
    return username.isEmpty ? withoutAt : username
  }

  static func title(for conversation: Conversation, currentUserId: String? = nil) -> String {
    if let name: String = conversation.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      return conversation.type == .direct ? usernameOnly(from: name) : name
    }

    if conversation.type == .direct,
      let participants: [ConversationParticipant] = conversation.participants
    {
      let normalizedCurrentUserId: String? = currentUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let peer: ConversationParticipant? = participants.first { participant in
        guard let normalizedCurrentUserId else {
          return true
        }
        return participant.userId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != normalizedCurrentUserId
      }
      if let peer {
        return usernameOnly(from: peer.userId)
      }
    }

    return conversation.type == .group ? "Группа" : "Диалог"
  }
}
