import AVFoundation
import Flutter
import Foundation

private enum UvcCameraError: Error {
    case invalidArgument(String)
    case illegalState(String)
    case notFound(String)
    case operationFailed(String)
}

private final class UvcCameraEventStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func emit(_ event: [String: Any]) {
        sink?(event)
    }
}

private final class UvcPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<String, Error>) -> Void

    init(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(UvcCameraError.operationFailed("Failed to serialize captured photo")))
            return
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = directory.appendingPathComponent("uvccamera_\(UUID().uuidString).jpg")

        do {
            try data.write(to: fileURL)
            completion(.success(fileURL.path))
        } catch {
            completion(.failure(error))
        }
    }
}

private final class UvcMovieFileOutputDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onFinished: ((Error?) -> Void)?

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        onFinished?(error)
    }
}

private final class UvcCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let id: Int
    let device: AVCaptureDevice
    let captureSession = AVCaptureSession()
    let texture = UvcCameraTexture()

    private(set) var textureId: Int64?

    var onRuntimeError: ((Error) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    private let textureRegistry: FlutterTextureRegistry
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let movieOutputDelegate = UvcMovieFileOutputDelegate()
    private let queue = DispatchQueue(label: "org.uvccamera.flutter.camera.session")

    private var photoDelegates: [UvcPhotoCaptureDelegate] = []
    private var observers: [NSObjectProtocol] = []

    init(id: Int, device: AVCaptureDevice, textureRegistry: FlutterTextureRegistry) {
        self.id = id
        self.device = device
        self.textureRegistry = textureRegistry
        super.init()
    }

    deinit {
        removeObservers()
        if let textureId {
            textureRegistry.unregisterTexture(textureId)
        }
    }

    func configureSession(preset: String) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw UvcCameraError.operationFailed("Unable to add camera input")
        }
        captureSession.addInput(input)

        let sessionPreset = Self.capturePreset(from: preset)
        if captureSession.canSetSessionPreset(sessionPreset) {
            captureSession.sessionPreset = sessionPreset
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw UvcCameraError.operationFailed("Unable to add video output")
        }
        captureSession.addOutput(videoOutput)

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        textureId = textureRegistry.register(texture)
        registerObservers()
    }

    func startRunning() {
        queue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    func stopRunning() {
        queue.sync {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func capturePhoto(completion: @escaping (Result<String, Error>) -> Void) {
        let settings = AVCapturePhotoSettings()
        var delegate: UvcPhotoCaptureDelegate?
        delegate = UvcPhotoCaptureDelegate { [weak self] result in
            completion(result)
            if let delegate {
                self?.photoDelegates.removeAll { $0 === delegate }
            }
        }

        guard let delegate else {
            completion(.failure(UvcCameraError.operationFailed("Failed to initialize photo capture delegate")))
            return
        }

        photoDelegates.append(delegate)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    func startVideoRecording() throws -> String {
        guard !movieOutput.isRecording else {
            throw UvcCameraError.illegalState("Video recording already in progress")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = directory.appendingPathComponent("uvccamera_\(UUID().uuidString).mov")
        movieOutputDelegate.onFinished = { [weak self] error in
            if let error {
                self?.onRuntimeError?(error)
            }
        }
        movieOutput.startRecording(to: fileURL, recordingDelegate: movieOutputDelegate)
        return fileURL.path
    }

    func stopVideoRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
    }

    func getSupportedModes() -> [[String: Any]] {
        var knownModes = Set<String>()
        var modes: [[String: Any]] = []

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dimensions.width)x\(dimensions.height)"
            if knownModes.contains(key) {
                continue
            }

            knownModes.insert(key)
            modes.append([
                "frameWidth": Int(dimensions.width),
                "frameHeight": Int(dimensions.height),
                "frameFormat": "yuyv"
            ])
        }

        return modes.sorted { lhs, rhs in
            let lhsArea = (lhs["frameWidth"] as? Int ?? 0) * (lhs["frameHeight"] as? Int ?? 0)
            let rhsArea = (rhs["frameWidth"] as? Int ?? 0) * (rhs["frameHeight"] as? Int ?? 0)
            return lhsArea < rhsArea
        }
    }

    func getPreviewMode() -> [String: Any] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return [
            "frameWidth": Int(dimensions.width),
            "frameHeight": Int(dimensions.height),
            "frameFormat": "yuyv"
        ]
    }

    func setPreviewMode(_ mode: [String: Any]) throws {
        guard let width = mode["frameWidth"] as? Int,
              let height = mode["frameHeight"] as? Int else {
            throw UvcCameraError.invalidArgument("Invalid preview mode")
        }

        guard let matchingFormat = device.formats.first(where: {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(dimensions.width) == width && Int(dimensions.height) == height
        }) else {
            throw UvcCameraError.notFound("No format available for \(width)x\(height)")
        }

        try device.lockForConfiguration()
        device.activeFormat = matchingFormat
        device.unlockForConfiguration()
    }

    static func capturePreset(from resolutionPreset: String) -> AVCaptureSession.Preset {
        switch resolutionPreset {
        case "min":
            return .cif352x288
        case "low":
            return .vga640x480
        case "medium":
            return .hd1280x720
        case "high":
            return .hd1920x1080
        case "max":
            return .high
        default:
            return .high
        }
    }

    private func registerObservers() {
        removeObservers()

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: captureSession,
            queue: .main
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? UvcCameraError.operationFailed("Unknown session runtime error")
            self?.onRuntimeError?(err)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            self?.onStatusMessage?("interrupted")
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            self?.onStatusMessage?("interruptionEnded")
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let textureId, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        texture.update(pixelBuffer: pixelBuffer)
        textureRegistry.textureFrameAvailable(textureId)
    }
}

public final class UvcCameraPlugin: NSObject, FlutterPlugin {
    private let nativeChannel: FlutterMethodChannel
    private let deviceEventHandler = UvcCameraEventStreamHandler()
    private let messenger: FlutterBinaryMessenger
    private let textureRegistry: FlutterTextureRegistry

    private var cameraIdCounter = 0
    private var cameraSessions: [Int: UvcCameraSession] = [:]

    private var errorEventHandlers: [Int: UvcCameraEventStreamHandler] = [:]
    private var statusEventHandlers: [Int: UvcCameraEventStreamHandler] = [:]
    private var buttonEventHandlers: [Int: UvcCameraEventStreamHandler] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = UvcCameraPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(plugin, channel: plugin.nativeChannel)

        let deviceChannel = FlutterEventChannel(name: "uvccamera/device_events", binaryMessenger: registrar.messenger())
        deviceChannel.setStreamHandler(plugin.deviceEventHandler)

        NotificationCenter.default.addObserver(
            plugin,
            selector: #selector(plugin.onCaptureDeviceConnected(_:)),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            plugin,
            selector: #selector(plugin.onCaptureDeviceDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
    }

    init(registrar: FlutterPluginRegistrar) {
        nativeChannel = FlutterMethodChannel(name: "uvccamera/native", binaryMessenger: registrar.messenger())
        messenger = registrar.messenger()
        textureRegistry = registrar.textures()
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cameraSessions.values.forEach { $0.stopRunning() }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "isSupported":
                result(try isSupported())
            case "getDevices":
                result(try getDevices())
            case "requestDevicePermission":
                requestDevicePermission(result: result)
            case "openCamera":
                result(try openCamera(arguments: call.arguments))
            case "closeCamera":
                try closeCamera(arguments: call.arguments)
                result(nil)
            case "getCameraTextureId":
                result(try getCameraTextureId(arguments: call.arguments))
            case "attachToCameraErrorCallback":
                try attachEventChannel(prefix: "error_events", handlers: &errorEventHandlers, arguments: call.arguments)
                result(nil)
            case "detachFromCameraErrorCallback":
                try detachEventChannel(handlers: &errorEventHandlers, arguments: call.arguments)
                result(nil)
            case "attachToCameraStatusCallback":
                try attachEventChannel(prefix: "status_events", handlers: &statusEventHandlers, arguments: call.arguments)
                result(nil)
            case "detachFromCameraStatusCallback":
                try detachEventChannel(handlers: &statusEventHandlers, arguments: call.arguments)
                result(nil)
            case "attachToCameraButtonCallback":
                try attachEventChannel(prefix: "button_events", handlers: &buttonEventHandlers, arguments: call.arguments)
                result(nil)
            case "detachFromCameraButtonCallback":
                try detachEventChannel(handlers: &buttonEventHandlers, arguments: call.arguments)
                result(nil)
            case "getSupportedModes":
                result(try getCameraSession(arguments: call.arguments).getSupportedModes())
            case "getPreviewMode":
                result(try getCameraSession(arguments: call.arguments).getPreviewMode())
            case "setPreviewMode":
                try setPreviewMode(arguments: call.arguments)
                result(nil)
            case "takePicture":
                try takePicture(arguments: call.arguments, result: result)
            case "startVideoRecording":
                try startVideoRecording(arguments: call.arguments, result: result)
            case "stopVideoRecording":
                try getCameraSession(arguments: call.arguments).stopVideoRecording()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(asFlutterError(error))
        }
    }

    private func isSupported() throws -> Bool {
        !discoverDevices().isEmpty
    }

    private func discoverDevices() -> [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 17.0, *) {
            deviceTypes.append(.external)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    private func getDevices() throws -> [String: Any] {
        Dictionary(uniqueKeysWithValues: discoverDevices().map { device in
            (device.uniqueID, [
                "name": device.uniqueID,
                "deviceClass": 14,
                "deviceSubclass": 2,
                "vendorId": 0,
                "productId": 0
            ])
        })
    }

    private func requestDevicePermission(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            result(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    result(granted)
                }
            }
        default:
            result(false)
        }
    }

    private func openCamera(arguments: Any?) throws -> Int {
        guard let arguments = arguments as? [String: Any],
              let deviceName = arguments["deviceName"] as? String,
              let resolutionPreset = arguments["resolutionPreset"] as? String else {
            throw UvcCameraError.invalidArgument("deviceName and resolutionPreset are required")
        }

        guard let device = discoverDevices().first(where: { $0.uniqueID == deviceName }) else {
            throw UvcCameraError.notFound("Unable to find camera device '\(deviceName)'")
        }

        cameraIdCounter += 1
        let session = UvcCameraSession(id: cameraIdCounter, device: device, textureRegistry: textureRegistry)
        session.onRuntimeError = { [weak self] error in
            self?.emitError(cameraId: session.id, code: "OperationFailed", message: error.localizedDescription)
        }
        session.onStatusMessage = { [weak self] status in
            self?.emitStatus(cameraId: session.id, event: status)
        }

        try session.configureSession(preset: resolutionPreset)
        session.startRunning()

        cameraSessions[cameraIdCounter] = session
        return cameraIdCounter
    }

    private func closeCamera(arguments: Any?) throws {
        let cameraId = try getCameraId(arguments)
        guard let session = cameraSessions.removeValue(forKey: cameraId) else {
            throw UvcCameraError.notFound("Unable to find camera '\(cameraId)'")
        }
        session.stopRunning()
        errorEventHandlers.removeValue(forKey: cameraId)
        statusEventHandlers.removeValue(forKey: cameraId)
        buttonEventHandlers.removeValue(forKey: cameraId)
    }

    private func getCameraTextureId(arguments: Any?) throws -> Int64 {
        let session = try getCameraSession(arguments: arguments)
        guard let textureId = session.textureId else {
            throw UvcCameraError.operationFailed("Texture is not initialized")
        }
        return textureId
    }

    private func getCameraSession(arguments: Any?) throws -> UvcCameraSession {
        let cameraId = try getCameraId(arguments)
        guard let session = cameraSessions[cameraId] else {
            throw UvcCameraError.notFound("Unable to find camera '\(cameraId)'")
        }
        return session
    }

    private func getCameraId(_ arguments: Any?) throws -> Int {
        guard let arguments = arguments as? [String: Any],
              let cameraId = arguments["cameraId"] as? Int else {
            throw UvcCameraError.invalidArgument("cameraId is required")
        }
        return cameraId
    }

    private func setPreviewMode(arguments: Any?) throws {
        guard let arguments = arguments as? [String: Any],
              let cameraId = arguments["cameraId"] as? Int,
              let previewMode = arguments["previewMode"] as? [String: Any],
              let session = cameraSessions[cameraId] else {
            throw UvcCameraError.invalidArgument("cameraId and previewMode are required")
        }
        try session.setPreviewMode(previewMode)
    }

    private func takePicture(arguments: Any?, result: @escaping FlutterResult) throws {
        let session = try getCameraSession(arguments: arguments)
        session.capturePhoto { captureResult in
            DispatchQueue.main.async {
                switch captureResult {
                case let .success(path):
                    result(path)
                case let .failure(error):
                    result(self.asFlutterError(error))
                }
            }
        }
    }

    private func startVideoRecording(arguments: Any?, result: @escaping FlutterResult) throws {
        guard let arguments = arguments as? [String: Any],
              let cameraId = arguments["cameraId"] as? Int,
              let videoRecordingMode = arguments["videoRecordingMode"] as? [String: Any],
              let session = cameraSessions[cameraId] else {
            throw UvcCameraError.invalidArgument("cameraId and videoRecordingMode are required")
        }

        try session.setPreviewMode(videoRecordingMode)
        result(try session.startVideoRecording())
    }

    private func attachEventChannel(
        prefix: String,
        handlers: inout [Int: UvcCameraEventStreamHandler],
        arguments: Any?
    ) throws {
        let cameraId = try getCameraId(arguments)
        if handlers[cameraId] != nil {
            return
        }

        let handler = UvcCameraEventStreamHandler()
        let channel = FlutterEventChannel(name: "uvccamera/camera@\(cameraId)/\(prefix)", binaryMessenger: messenger)
        channel.setStreamHandler(handler)
        handlers[cameraId] = handler
    }

    private func detachEventChannel(
        handlers: inout [Int: UvcCameraEventStreamHandler],
        arguments: Any?
    ) throws {
        let cameraId = try getCameraId(arguments)
        handlers.removeValue(forKey: cameraId)
    }

    private func emitError(cameraId: Int, code _: String, message: String) {
        errorEventHandlers[cameraId]?.emit([
            "cameraId": cameraId,
            "error": [
                "type": "previewInterrupted",
                "reason": message
            ]
        ])
    }

    private func emitStatus(cameraId: Int, event: String) {
        statusEventHandlers[cameraId]?.emit([
            "cameraId": cameraId,
            "payload": [
                "statusClass": "control",
                "event": 0,
                "selector": 0,
                "statusAttribute": "unknown",
                "eventName": event
            ]
        ])
    }

    @objc private func onCaptureDeviceConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else {
            return
        }

        deviceEventHandler.emit([
            "device": [
                "name": device.uniqueID,
                "deviceClass": 14,
                "deviceSubclass": 2,
                "vendorId": 0,
                "productId": 0
            ],
            "type": "attached"
        ])
    }

    @objc private func onCaptureDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else {
            return
        }

        deviceEventHandler.emit([
            "device": [
                "name": device.uniqueID,
                "deviceClass": 14,
                "deviceSubclass": 2,
                "vendorId": 0,
                "productId": 0
            ],
            "type": "detached"
        ])

        for (cameraId, session) in cameraSessions where session.device.uniqueID == device.uniqueID {
            session.stopRunning()
            cameraSessions.removeValue(forKey: cameraId)
            emitError(cameraId: cameraId, code: "OperationFailed", message: "Camera device was disconnected")
        }
    }

    private func asFlutterError(_ error: Error) -> FlutterError {
        if let cameraError = error as? UvcCameraError {
            switch cameraError {
            case let .invalidArgument(message):
                return FlutterError(code: "InvalidArgument", message: message, details: nil)
            case let .illegalState(message):
                return FlutterError(code: "IllegalState", message: message, details: nil)
            case let .notFound(message):
                return FlutterError(code: "NotFound", message: message, details: nil)
            case let .operationFailed(message):
                return FlutterError(code: "OperationFailed", message: message, details: nil)
            }
        }

        return FlutterError(code: "Unknown", message: error.localizedDescription, details: nil)
    }
}
