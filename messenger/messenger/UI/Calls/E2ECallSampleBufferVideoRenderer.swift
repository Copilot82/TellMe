@preconcurrency import AVFoundation
import UIKit
import WebRTC

final class E2ECallSampleBufferDisplayView: UIView {
  private let displayLayer: AVSampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
  private var rotationRawValue: Int = 0

  var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
    displayLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureLayer()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureLayer() {
    backgroundColor = .black
    layer.addSublayer(displayLayer)
    displayLayer.backgroundColor = UIColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutDisplayLayer()
  }

  func setVideoRotationRawValue(_ rawValue: Int) {
    guard rotationRawValue != rawValue else {
      return
    }

    rotationRawValue = rawValue
    layoutDisplayLayer()
  }

  private func layoutDisplayLayer() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    displayLayer.bounds = CGRect(origin: .zero, size: displayLayerBoundsSize)
    displayLayer.setAffineTransform(displayLayerTransform)
    CATransaction.commit()
  }

  private var displayLayerBoundsSize: CGSize {
    switch rotationRawValue {
    case 90, 270:
      return CGSize(width: bounds.height, height: bounds.width)
    default:
      return bounds.size
    }
  }

  private var displayLayerTransform: CGAffineTransform {
    switch rotationRawValue {
    case 90:
      return CGAffineTransform(rotationAngle: .pi / 2)
    case 180:
      return CGAffineTransform(rotationAngle: .pi)
    case 270:
      return CGAffineTransform(rotationAngle: -.pi / 2)
    default:
      return .identity
    }
  }
}

final class E2ECallSampleBufferVideoRenderer: NSObject, RTCVideoRenderer {
  let displayView: E2ECallSampleBufferDisplayView = E2ECallSampleBufferDisplayView()

  private let renderQueue = DispatchQueue(label: "com.example.messenger.call.pip.sample-buffer-renderer")
  private let counterLock = NSLock()
  private let frameDuration = CMTime(value: 1, timescale: 30)

  private var formatDescription: CMVideoFormatDescription?
  private var formatDescriptionDimensions: CMVideoDimensions?
  private var nextPresentationTime: CMTime = .zero
  private var currentRotationRawValue: Int = 0
  private var sampleBufferFrameCount: Int = 0
  private var enqueuedFrameCount: Int = 0
  private var droppedFrameCount: Int = 0

  func setSize(_ size: CGSize) {
    let dimensions = CMVideoDimensions(
      width: Int32(max(1, Int(size.width.rounded()))),
      height: Int32(max(1, Int(size.height.rounded())))
    )

    renderQueue.async { [weak self] in
      guard let self else {
        return
      }

      if self.formatDescriptionDimensions?.width != dimensions.width
        || self.formatDescriptionDimensions?.height != dimensions.height
      {
        self.formatDescription = nil
        self.formatDescriptionDimensions = dimensions
      }
    }
  }

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame else {
      recordDroppedFrame()
      return
    }

    let rotationRawValue = frame.rotation.rawValue
    if let pixelBufferFrame = frame.buffer as? RTCCVPixelBuffer {
      render(pixelBuffer: SendablePixelBuffer(pixelBufferFrame.pixelBuffer), rotationRawValue: rotationRawValue)
      return
    }

    render(
      i420Buffer: SendableI420Buffer(frame.buffer.toI420()),
      rotationRawValue: rotationRawValue
    )
  }

  func enqueuePlaceholderFrameIfNeeded(size: CGSize) {
    guard currentSampleBufferFrameCount() == 0 else {
      return
    }

    let width = max(16, Int(size.width.rounded()))
    let height = max(16, Int(size.height.rounded()))
    renderQueue.async { [weak self] in
      guard let self, self.currentSampleBufferFrameCount() == 0 else {
        return
      }

      guard let pixelBuffer = self.makeBlackPixelBuffer(width: width, height: height),
        let sampleBuffer = self.makeSampleBuffer(pixelBuffer: pixelBuffer)
      else {
        self.recordDroppedFrame()
        return
      }

      let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
      DispatchQueue.main.async { [weak self, sendableSampleBuffer] in
        self?.enqueue(sendableSampleBuffer.value, rotationRawValue: 0)
      }
    }
  }

  private func render(pixelBuffer: SendablePixelBuffer, rotationRawValue: Int) {
    renderQueue.async { [weak self, pixelBuffer] in
      guard let self else {
        return
      }

      guard let sampleBuffer = self.makeSampleBuffer(pixelBuffer: pixelBuffer.value) else {
        self.recordDroppedFrame()
        return
      }

      let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
      DispatchQueue.main.async { [weak self, sendableSampleBuffer] in
        self?.enqueue(sendableSampleBuffer.value, rotationRawValue: rotationRawValue)
      }
    }
  }

  private func render(i420Buffer: SendableI420Buffer, rotationRawValue: Int) {
    renderQueue.async { [weak self, i420Buffer] in
      guard let self else {
        return
      }

      guard let pixelBuffer = self.makePixelBuffer(from: i420Buffer.value) else {
        self.recordDroppedFrame()
        return
      }

      guard let sampleBuffer = self.makeSampleBuffer(pixelBuffer: pixelBuffer) else {
        self.recordDroppedFrame()
        return
      }

      let sendableSampleBuffer = SendableSampleBuffer(sampleBuffer)
      DispatchQueue.main.async { [weak self, sendableSampleBuffer] in
        self?.enqueue(sendableSampleBuffer.value, rotationRawValue: rotationRawValue)
      }
    }
  }

#if DEBUG
  var enqueuedFrameCountForTesting: Int {
    counterLock.withLock {
      enqueuedFrameCount
    }
  }

  var sampleBufferFrameCountForTesting: Int {
    counterLock.withLock {
      sampleBufferFrameCount
    }
  }

  var droppedFrameCountForTesting: Int {
    counterLock.withLock {
      droppedFrameCount
    }
  }
#endif

  func flush() {
    DispatchQueue.main.async { [weak self] in
      self?.displayView.sampleBufferDisplayLayer.flush()
    }

    renderQueue.async { [weak self] in
      self?.resetTiming()
    }
  }

  private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    guard let formatDescription = formatDescription(for: pixelBuffer) else {
      return nil
    }

    var timingInfo = CMSampleTimingInfo(
      duration: frameDuration,
      presentationTimeStamp: nextPresentationTime,
      decodeTimeStamp: .invalid
    )
    nextPresentationTime = nextPresentationTime + frameDuration

    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timingInfo,
      sampleBufferOut: &sampleBuffer
    )

    guard status == noErr, let sampleBuffer else {
      return nil
    }

    markSampleBufferForImmediateDisplay(sampleBuffer)
    recordSampleBufferFrame()
    return sampleBuffer
  }

  private func makePixelBuffer(from i420Buffer: RTCI420BufferProtocol) -> CVPixelBuffer? {
    let width = Int(i420Buffer.width)
    let height = Int(i420Buffer.height)
    guard width > 0, height > 0 else {
      return nil
    }

    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      attributes as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
      let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
      return nil
    }

    copyLumaPlane(
      from: i420Buffer,
      to: yBaseAddress.assumingMemoryBound(to: UInt8.self),
      destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
      width: width,
      height: height
    )
    copyChromaPlane(
      from: i420Buffer,
      to: uvBaseAddress.assumingMemoryBound(to: UInt8.self),
      destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    )
    return pixelBuffer
  }

  private func makeBlackPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return nil
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let rowPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
      let destination = rowPointer.advanced(by: row * bytesPerRow)
      memset(destination, 0, width * 4)
      for column in 0..<width {
        destination[column * 4 + 3] = 0xFF
      }
    }
    return pixelBuffer
  }

  private func copyLumaPlane(
    from i420Buffer: RTCI420BufferProtocol,
    to destination: UnsafeMutablePointer<UInt8>,
    destinationStride: Int,
    width: Int,
    height: Int
  ) {
    let source = i420Buffer.dataY
    let sourceStride = Int(i420Buffer.strideY)
    for row in 0..<height {
      memcpy(
        destination.advanced(by: row * destinationStride),
        source.advanced(by: row * sourceStride),
        width
      )
    }
  }

  private func copyChromaPlane(
    from i420Buffer: RTCI420BufferProtocol,
    to destination: UnsafeMutablePointer<UInt8>,
    destinationStride: Int
  ) {
    let chromaWidth = Int(i420Buffer.chromaWidth)
    let chromaHeight = Int(i420Buffer.chromaHeight)
    let sourceU = i420Buffer.dataU
    let sourceV = i420Buffer.dataV
    let strideU = Int(i420Buffer.strideU)
    let strideV = Int(i420Buffer.strideV)

    for row in 0..<chromaHeight {
      let destinationRow = destination.advanced(by: row * destinationStride)
      let sourceURow = sourceU.advanced(by: row * strideU)
      let sourceVRow = sourceV.advanced(by: row * strideV)
      for column in 0..<chromaWidth {
        destinationRow[column * 2] = sourceURow[column]
        destinationRow[column * 2 + 1] = sourceVRow[column]
      }
    }
  }

  private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
    let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
    let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

    if let formatDescription,
      formatDescriptionDimensions?.width == width,
      formatDescriptionDimensions?.height == height
    {
      return formatDescription
    }

    var newFormatDescription: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &newFormatDescription
    )

    guard status == noErr, let newFormatDescription else {
      return nil
    }

    formatDescription = newFormatDescription
    formatDescriptionDimensions = CMVideoDimensions(width: width, height: height)
    return newFormatDescription
  }

  private func markSampleBufferForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) else {
      return
    }
    guard CFArrayGetCount(attachments) > 0 else {
      return
    }
    let attachment = unsafeBitCast(
      CFArrayGetValueAtIndex(attachments, 0),
      to: CFMutableDictionary.self
    )

    CFDictionarySetValue(
      attachment,
      Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
      Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
    )
  }

  private func enqueue(_ sampleBuffer: CMSampleBuffer, rotationRawValue: Int) {
    let layer = displayView.sampleBufferDisplayLayer
    if layer.status == .failed {
      layer.flush()
      renderQueue.async { [weak self] in
        self?.resetTiming()
      }
    }

    apply(rotationRawValue: rotationRawValue)

    guard layer.isReadyForMoreMediaData else {
      recordDroppedFrame()
      return
    }

    layer.enqueue(sampleBuffer)
    recordEnqueuedFrame()
  }

  private func apply(rotationRawValue: Int) {
    guard currentRotationRawValue != rotationRawValue else {
      return
    }

    currentRotationRawValue = rotationRawValue
    displayView.setVideoRotationRawValue(rotationRawValue)
  }

  private func resetTiming() {
    nextPresentationTime = .zero
  }

  private func recordEnqueuedFrame() {
    counterLock.withLock {
      enqueuedFrameCount += 1
    }
  }

  private func recordSampleBufferFrame() {
    counterLock.withLock {
      sampleBufferFrameCount += 1
    }
  }

  private func recordDroppedFrame() {
    counterLock.withLock {
      droppedFrameCount += 1
    }
  }

  private func currentSampleBufferFrameCount() -> Int {
    counterLock.withLock {
      sampleBufferFrameCount
    }
  }
}

private extension NSLock {
  func withLock<T>(_ operation: () -> T) -> T {
    lock()
    defer {
      unlock()
    }
    return operation()
  }
}

private struct SendablePixelBuffer: @unchecked Sendable {
  let value: CVPixelBuffer

  init(_ value: CVPixelBuffer) {
    self.value = value
  }
}

private struct SendableSampleBuffer: @unchecked Sendable {
  let value: CMSampleBuffer

  init(_ value: CMSampleBuffer) {
    self.value = value
  }
}

private struct SendableI420Buffer: @unchecked Sendable {
  let value: RTCI420BufferProtocol

  init(_ value: RTCI420BufferProtocol) {
    self.value = value
  }
}
