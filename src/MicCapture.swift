import AVFoundation
import CoreAudio

/// Records one specific microphone with AVCaptureSession, delivering 16 kHz mono Float32.
///
/// AVAudioEngine always opens the system *default* input first, even when you then point it at
/// another mic. If the default is AirPods, that alone flips them into Bluetooth call mode: music
/// drops to low quality and the audio reconfiguration kills the recording. AVCaptureSession opens
/// only the device it's given, so AirPods stay in music mode.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Called on the capture queue with each chunk of 16 kHz mono samples.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?
    let deviceUID: String

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "Verbaline.micCapture", qos: .userInteractive)

    init?(device: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        deviceUID = device.uniqueID
        super.init()
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); return nil }
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return nil }
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// Blocks until the mic is running (typically well under 0.1 s).
    func start() { session.startRunning() }
    func stop() { session.stopRunning() }
    var isRunning: Bool { session.isRunning }

    /// The Mac's built-in microphone as a capture device, if it has one.
    static func builtInDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Only accept what we asked for; anything else would be misread as noise.
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 1,
              asbd.mSampleRate == AudioRecorder.sampleRate else { return }

        var list = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = list.mBuffers.mData, list.mBuffers.mDataByteSize > 0 else { return }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        onSamples?(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        withExtendedLifetime(block) {}
    }
}
