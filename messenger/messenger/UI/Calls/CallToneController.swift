import AVFoundation
import Foundation

protocol CallToneAudioPlaying: AnyObject {
  func playTone(frequency: Double, duration: TimeInterval)
  func stop()
}

protocol CallToneRepeatingTimer: AnyObject {
  func invalidate()
}

protocol CallToneTimerScheduling: AnyObject {
  func scheduleRepeatingTimer(
    interval: TimeInterval,
    handler: @escaping () -> Void
  ) -> CallToneRepeatingTimer
}

final class CallToneController {
  private let audioPlayer: CallToneAudioPlaying
  private let timerScheduler: CallToneTimerScheduling
  private var repeatingTimer: CallToneRepeatingTimer?

  init(
    audioPlayer: CallToneAudioPlaying = AVAudioCallTonePlayer(),
    timerScheduler: CallToneTimerScheduling = FoundationCallToneTimerScheduler()
  ) {
    self.audioPlayer = audioPlayer
    self.timerScheduler = timerScheduler
  }

  func startOutgoingRingback() {
    startRepeatingTone(frequency: 440, duration: 0.28, interval: 2.0)
  }

  func startIncomingRingtone() {
    startRepeatingTone(frequency: 660, duration: 0.18, interval: 1.2)
  }

  func playConnectedCheckTone() {
    stopRepeatingTone()
    audioPlayer.playTone(frequency: 880, duration: 0.22)
  }

  func startMediaCheckTone() {
    startRepeatingTone(frequency: 880, duration: 0.22, interval: 1.0)
  }

  func stop() {
    stopRepeatingTone()
    audioPlayer.stop()
  }

  private func startRepeatingTone(frequency: Double, duration: TimeInterval, interval: TimeInterval) {
    stopRepeatingTone()
    audioPlayer.playTone(frequency: frequency, duration: duration)
    repeatingTimer = timerScheduler.scheduleRepeatingTimer(interval: interval) { [weak self] in
      self?.audioPlayer.playTone(frequency: frequency, duration: duration)
    }
  }

  private func stopRepeatingTone() {
    repeatingTimer?.invalidate()
    repeatingTimer = nil
  }
}

private final class FoundationCallToneTimer: CallToneRepeatingTimer {
  private let timer: Timer

  init(timer: Timer) {
    self.timer = timer
  }

  func invalidate() {
    timer.invalidate()
  }
}

private final class FoundationCallToneTimerScheduler: CallToneTimerScheduling {
  func scheduleRepeatingTimer(
    interval: TimeInterval,
    handler: @escaping () -> Void
  ) -> CallToneRepeatingTimer {
    let timer: Timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
      handler()
    }
    return FoundationCallToneTimer(timer: timer)
  }
}

private final class AVAudioCallTonePlayer: CallToneAudioPlaying {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var playbackGeneration: UInt64 = 0

  func playTone(frequency: Double, duration: TimeInterval) {
    playbackGeneration &+= 1
    let generation = playbackGeneration
    let audioSession = AVAudioSession.sharedInstance()

    let engine: AVAudioEngine
    let player: AVAudioPlayerNode
    if let currentEngine = self.engine, let currentPlayer = self.player {
      engine = currentEngine
      player = currentPlayer
    } else {
      engine = AVAudioEngine()
      player = AVAudioPlayerNode()
      guard let format: AVAudioFormat = makeToneFormat(audioSession: audioSession) else {
        return
      }
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      self.engine = engine
      self.player = player
    }

    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        return
      }
    }

    let playbackFormat: AVAudioFormat = player.outputFormat(forBus: 0)
    guard playbackFormat.channelCount > 0,
      let buffer: AVAudioPCMBuffer = makeToneBuffer(
        frequency: frequency,
        duration: duration,
        format: playbackFormat
      )
    else {
      return
    }

    player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.playbackGeneration == generation else {
          return
        }
        self.stop()
      }
    }
    if !player.isPlaying {
      player.play()
    }
  }

  func stop() {
    playbackGeneration &+= 1
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
  }

  private func makeToneFormat(audioSession: AVAudioSession) -> AVAudioFormat? {
    let sampleRate: Double = audioSession.sampleRate > 0 ? audioSession.sampleRate : 44_100
    let channelCount: AVAudioChannelCount = {
      let outputChannels: Int = audioSession.outputNumberOfChannels
      return AVAudioChannelCount(max(1, min(outputChannels, 2)))
    }()
    return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
  }

  private func makeToneBuffer(
    frequency: Double,
    duration: TimeInterval,
    format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let sampleRate: Double = format.sampleRate > 0 ? format.sampleRate : 44_100
    let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * duration)))
    guard format.channelCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      return nil
    }

    buffer.frameLength = frameCount
    guard let channels = buffer.floatChannelData else {
      return nil
    }

    let amplitude: Float = 0.18
    for channel in 0..<Int(format.channelCount) {
      let channelData = channels[channel]
      for frame in 0..<Int(frameCount) {
        let phase: Double = 2.0 * .pi * frequency * Double(frame) / sampleRate
        channelData[frame] = Float(sin(phase)) * amplitude
      }
    }

    return buffer
  }
}
