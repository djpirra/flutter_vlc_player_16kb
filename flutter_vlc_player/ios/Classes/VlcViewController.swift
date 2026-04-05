import Flutter
import Foundation
import VLCKit
import UIKit

public class VLCViewController: NSObject, FlutterPlatformView {
    var hostedView: UIView
    var vlcMediaPlayer: VLCMediaPlayer
    var mediaEventChannel: FlutterEventChannel
    let mediaEventChannelHandler: VLCPlayerEventStreamHandler
    var rendererEventChannel: FlutterEventChannel
    let rendererEventChannelHandler: VLCRendererEventStreamHandler
    var rendererdiscoverers: [VLCRendererDiscoverer] = .init()
    private var vlcView: UIView!
    private var seekWorkItem: DispatchWorkItem?
    
    // Dedicated serial queue for reading libvlc properties OFF the timer/main thread.
    // This queue must NEVER be used for set_position or any mutating libvlc call.
    private let vlcReadQueue = DispatchQueue(label: "com.gridstreamr.vlc_read", qos: .userInitiated)
    
    // Guards to prevent seek flooding (main-thread only)
    private var isSeekInFlight: Bool = false
    private var coalescedSeekTarget: Int64? = nil
    
    // Caches — updated only from safe contexts, read from main thread
    private var lastKnownPosition: Int = 0
    private var lastKnownDuration: Int = 0
    private var lastKnownIsPlaying: Bool = false

    public func view() -> UIView {
        return self.hostedView
    }
    
    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        let mediaEventChannel = FlutterEventChannel(
            name: "flutter_video_plugin/getVideoEvents_\(viewId)",
            binaryMessenger: messenger
        )
        let rendererEventChannel = FlutterEventChannel(
            name: "flutter_video_plugin/getRendererEvents_\(viewId)",
            binaryMessenger: messenger
        )
        
        self.hostedView = UIView(frame: frame)
        self.hostedView.backgroundColor = .black
        self.hostedView.isOpaque = true
        
        self.vlcView = UIView(frame: self.hostedView.bounds)
        self.vlcView.backgroundColor = .black
        self.vlcView.isOpaque = true
        self.vlcView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.hostedView.addSubview(self.vlcView)
        
        let library = VLCLibrary.shared()
        self.vlcMediaPlayer = VLCMediaPlayer(library: library)
        self.mediaEventChannel = mediaEventChannel
        self.mediaEventChannelHandler = VLCPlayerEventStreamHandler()
        self.mediaEventChannelHandler.player = self.vlcMediaPlayer
        self.rendererEventChannel = rendererEventChannel
        self.rendererEventChannelHandler = VLCRendererEventStreamHandler()
        
        self.mediaEventChannel.setStreamHandler(self.mediaEventChannelHandler)
        self.rendererEventChannel.setStreamHandler(self.rendererEventChannelHandler)
        self.vlcMediaPlayer.drawable = self.vlcView
        self.vlcMediaPlayer.delegate = self.mediaEventChannelHandler
        
        // 250ms update period is safe for VLCKit 4.0
        self.vlcMediaPlayer.minimalTimePeriod = 250000 
    }
    
    public func play() {
        self.vlcMediaPlayer.play()
    }
    
    public func pause() {
        self.vlcMediaPlayer.pause()
    }
    
    public func stop() {
        self.vlcMediaPlayer.stop()
    }
    
    public var isPlaying: Bool {
        return self.vlcMediaPlayer.isPlaying
    }
    
    public var isSeekable: Bool {
        // This is a fast check in VLCKit usually
        return self.vlcMediaPlayer.isSeekable
    }
    
    public func setLooping(isLooping: Bool) {
        self.vlcMediaPlayer.media?.addOption(isLooping ? "--loop" : "--no-loop")
    }
    
    public func seek(position: Int64) {
        // Cancel any pending debounce timer
        self.seekWorkItem?.cancel()
        
        // If a seek is already executing in libvlc, coalesce to the latest target
        if self.isSeekInFlight {
            self.coalescedSeekTarget = position
            return
        }
        
        // Short 50ms coalesce window to batch rapid slider moves
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.executeSeek(position: position)
        }
        
        self.seekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
    
    private func executeSeek(position: Int64) {
        self.isSeekInFlight = true
        
        // CRITICAL: setPosition ultimately calls libvlc_media_player_set_position
        // which acquires vlc_player_Lock. This MUST NOT run on the vlcReadQueue
        // because the timer callbacks that update time also dispatch there.
        // Use a GCD global concurrent queue — completely isolated from everything.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let rawDuration = self.vlcMediaPlayer.media?.length.value?.int64Value ?? 0
            let isMicro = rawDuration > 20_000_000
            let duration = isMicro ? (rawDuration / 1000) : rawDuration
            
            // ALWAYS use setPosition (fraction 0..1) rather than setTime.
            // setTime triggers synchronous timeChangeUpdate callbacks that
            // dispatch_sync on _timeChangeLockQueue → deadlock chain.
            if duration > 0 {
                let percent = Double(position) / Double(duration)
                let clampedPercent = max(0.0, min(1.0, percent))
                self.vlcMediaPlayer.position = clampedPercent
            } else {
                // Fallback: no duration known yet — use setTime best-effort
                let targetTime = isMicro ? (position * 1000) : position
                self.vlcMediaPlayer.time = VLCTime(number: NSNumber(value: targetTime))
            }
            
            // Let VLCKit's watch_time callbacks naturally propagate the new position.
            // Do NOT call refreshCaches or read any player properties here.
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isSeekInFlight = false
                
                // If another seek came in while we were executing, fire it now
                if let next = self.coalescedSeekTarget {
                    self.coalescedSeekTarget = nil
                    self.executeSeek(position: next)
                }
            }
        }
    }
    
    public var position: Int {
        return self.lastKnownPosition
    }
    
    public var duration: Int {
        return self.lastKnownDuration
    }
    
    public func setVolume(volume: Int64) {
        self.vlcMediaPlayer.audio?.volume = Int32(volume)
    }
    
    public var volume: Int32 {
        self.vlcMediaPlayer.audio?.volume ?? 100
    }
    
    public func setPlaybackSpeed(speed: Float) {
        self.vlcMediaPlayer.rate = speed
    }
    
    public var playbackSpeed: Float {
        self.vlcMediaPlayer.rate
    }
    
    public func takeSnapshot() -> String? {
        guard let videoView = self.vlcMediaPlayer.drawable as? UIView else { return nil }
        let size = videoView.frame.size
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let rec = videoView.frame
        videoView.drawHierarchy(in: rec, afterScreenUpdates: false)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let byteArray = (image ?? UIImage()).pngData()
        
        return byteArray?.base64EncodedString()
    }
    
    public var spuTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.trackDictionary(type: "textTracks").count)
    }
    
    public var spuTracks: [Int: String] {
        self.vlcMediaPlayer.trackDictionary(type: "textTracks")
    }
    
    public func setSpuTrack(spuTrackNumber: Int32) {
        self.vlcMediaPlayer.selectTrack(at: Int(spuTrackNumber), type: 2)
    }
    
    public var spuTrack: Int32 {
        Int32(self.vlcMediaPlayer.getSelectedTrackIndex(type: "textTracks"))
    }
    
    public func setSpuDelay(delay: Int) {
        self.vlcMediaPlayer.currentVideoSubTitleDelay = delay
    }
    
    public var spuDelay: Int {
        self.vlcMediaPlayer.currentVideoSubTitleDelay
    }
    
    public func addSubtitleTrack(uri: String, isSelected: Bool) {
        guard let url = URL(string: uri) else { return }
        self.vlcMediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: isSelected)
    }
    
    public func setSubtitleHeightScale(scale: Float) {
        self.vlcMediaPlayer.currentSubTitleFontScale = scale
    }
    
    public var audioTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.trackDictionary(type: "audioTracks").count)
    }
    
    public var audioTracks: [Int: String] {
        self.vlcMediaPlayer.trackDictionary(type: "audioTracks")
    }
    
    public func setAudioTrack(audioTrackNumber: Int32) {
        self.vlcMediaPlayer.selectTrack(at: Int(audioTrackNumber), type: 0)
    }
    
    public var audioTrack: Int32 {
        Int32(self.vlcMediaPlayer.getSelectedTrackIndex(type: "audioTracks"))
    }
    
    public func setAudioDelay(delay: Int) {
        self.vlcMediaPlayer.currentAudioPlaybackDelay = delay
    }
    
    public var audioDelay: Int {
        self.vlcMediaPlayer.currentAudioPlaybackDelay
    }
    
    public func addAudioTrack(uri: String, isSelected: Bool) {
        guard let url = URL(string: uri) else { return }
        self.vlcMediaPlayer.addPlaybackSlave(url, type: .audio, enforce: isSelected)
    }
    
    public var videoTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.trackDictionary(type: "videoTracks").count)
    }
    
    public var videoTracks: [Int: String] {
        self.vlcMediaPlayer.trackDictionary(type: "videoTracks")
    }
    
    public func setVideoTrack(videoTrackNumber: Int32) {
        self.vlcMediaPlayer.selectTrack(at: Int(videoTrackNumber), type: 1)
    }
    
    public var videoTrack: Int32 {
        Int32(self.vlcMediaPlayer.getSelectedTrackIndex(type: "videoTracks"))
    }
    
    public func setVideoScale(scale: Float) {
        self.vlcMediaPlayer.scaleFactor = scale
    }
    
    public var videoScale: Float {
        self.vlcMediaPlayer.scaleFactor
    }
    
    public func setVideoAspectRatio(aspectRatio: String) {
        self.vlcMediaPlayer.videoAspectRatio = aspectRatio
    }
    
    public var videoAspectRatio: String {
        return self.vlcMediaPlayer.videoAspectRatio ?? "1"
    }
    
    public var availableRendererServices: [String] {
        self.vlcMediaPlayer.rendererServices()
    }
    
    public func startRendererScanning() {
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        let rendererServices = self.vlcMediaPlayer.rendererServices()
        for rendererService in rendererServices {
            guard let rendererDiscoverer
                = VLCRendererDiscoverer(name: rendererService)
            else {
                continue
            }
            rendererDiscoverer.delegate = self.rendererEventChannelHandler
            rendererDiscoverer.start()
            self.rendererdiscoverers.append(rendererDiscoverer)
        }
    }
    
    public func stopRendererScanning() {
        for rendererDiscoverer in self.rendererdiscoverers {
            rendererDiscoverer.stop()
            rendererDiscoverer.delegate = nil
        }
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        if self.vlcMediaPlayer.isPlaying {
            self.vlcMediaPlayer.pause()
        }
        self.vlcMediaPlayer.setRendererItem(nil)
    }
    
    public var rendererDevices: [String: String] {
        var rendererDevices: [String: String] = [:]
        let rendererItems = self.rendererEventChannelHandler.renderItems
        for (_, item) in rendererItems.enumerated() {
            rendererDevices[item.name] = item.name
        }
        return rendererDevices
    }
    
    public func cast(rendererDevice: String) {
        if self.vlcMediaPlayer.isPlaying {
            self.vlcMediaPlayer.pause()
        }
        let rendererItems = self.rendererEventChannelHandler.renderItems
        let rendererItem = rendererItems.first {
            $0.name.contains(rendererDevice)
        }
        self.vlcMediaPlayer.setRendererItem(rendererItem)
        self.vlcMediaPlayer.play()
    }
    
    public func startRecording(saveDirectory: String) -> Bool {
        self.vlcMediaPlayer.startRecording(atPath: saveDirectory)
        return true
    }
    
    public func stopRecording() -> Bool {
        self.vlcMediaPlayer.stopRecording()
        return true
    }
    
    public func dispose() {
        self.mediaEventChannel.setStreamHandler(nil)
        self.rendererEventChannel.setStreamHandler(nil)
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        self.vlcMediaPlayer.stop()
    }
    
    func setMediaPlayerUrl(uri: String, isAssetUrl: Bool, autoPlay: Bool, hwAcc: Int, options: [String]) {
        self.vlcMediaPlayer.stop()
        
        var media: VLCMedia?
        if isAssetUrl {
            guard let path = Bundle.main.path(forResource: uri, ofType: nil)
            else {
                return
            }
            media = VLCMedia(path: path)
        }
        else {
            guard let url = URL(string: uri)
            else {
                return
            }
            media = VLCMedia(url: url)
        }
        
        guard let media = media else { return }
        
        if !options.isEmpty {
            for option in options {
                media.addOption(option)
            }
        }
        
        switch HWAccellerationType(rawValue: hwAcc) {
        case .HW_ACCELERATION_DISABLED:
            media.addOption("--codec=avcodec")
        case .HW_ACCELERATION_DECODING:
            media.addOption("--codec=all")
            media.addOption(":no-mediacodec-dr")
            media.addOption(":no-omxil-dr")
        case .HW_ACCELERATION_FULL:
            media.addOption("--codec=all")
        case .HW_ACCELERATION_AUTOMATIC:
            break
        case .none:
            break
        }
        
        self.vlcMediaPlayer.media = media
        self.vlcMediaPlayer.play()
        if !autoPlay {
            self.vlcMediaPlayer.stop()
        }
    }
}

class VLCRendererEventStreamHandler: NSObject, FlutterStreamHandler, VLCRendererDiscovererDelegate {
    private var rendererEventSink: FlutterEventSink?
    var renderItems: [VLCRendererItem] = .init()
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.rendererEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.rendererEventSink = nil
        return nil
    }
    
    @objc func rendererDiscovererItemAdded(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        self.renderItems.append(item)
        
        guard let rendererEventSink = self.rendererEventSink else { return }
        rendererEventSink([
            "event": "attached",
            "id": item.name,
            "name": item.name,
        ])
    }
    
    @objc func rendererDiscovererItemDeleted(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        if let index = renderItems.firstIndex(of: item) {
            self.renderItems.remove(at: index)
        }
        
        guard let rendererEventSink = self.rendererEventSink else { return }
        rendererEventSink([
            "event": "detached",
            "id": item.name,
            "name": item.name,
        ])
    }
}

class VLCPlayerEventStreamHandler: NSObject, FlutterStreamHandler, VLCMediaPlayerDelegate {
    private var mediaEventSink: FlutterEventSink?
    weak var player: VLCMediaPlayer?
    
    // Dedicated read queue — reads happen OFF the timer thread to avoid
    // calling libvlc_media_player_* while timer.lock is held.
    private let vlcReadQueue = DispatchQueue(label: "com.gridstreamr.vlc_event_read", qos: .userInitiated)
    
    // CRITICAL: isPlaying must NEVER be read from a timer callback.
    // libvlc_media_player_is_playing needs vlc_player_Lock, but timer
    // callbacks run inline on the timer thread which holds timer.lock.
    // Calling vlc_player_Lock while timer.lock is held triggers:
    //   Assertion failed: (!vlc_mutex_held(&player->timer.lock))
    // We cache isPlaying from state-change events (which fire on a safe thread).
    private var cachedIsPlaying: Bool = false
    
    override init() {
        super.init()
    }
    
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.mediaEventSink = events
        return nil
    }
    
    func onCancel(withArguments _: Any?) -> FlutterError? {
        self.mediaEventSink = nil
        return nil
    }
    
    @objc func mediaPlayerLengthChanged(_ length: Int64) {
        guard let mediaEventSink = self.mediaEventSink else { return }
        let isMicrosecond = length > 20_000_000
        let normalizedLength = isMicrosecond ? (length / 1000) : length
        
        DispatchQueue.main.async {
            mediaEventSink(["event": "timeChanged", "duration": NSNumber(value: normalizedLength)])
        }
    }
    
    @objc func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard let mediaEventSink = self.mediaEventSink, let player = self.player else { return }
        
        // State-change callbacks (HandleMediaInstanceStateChanged) dispatch through
        // VLCEventsHandler. With VLCEventsDefaultConfiguration (dispatchQueue=nil),
        // they run inline on the libvlc event thread. This thread does NOT hold
        // timer.lock, so calling player.isPlaying here is safe.
        //
        // However, to be extra safe, dispatch all reads to vlcReadQueue (async)
        // so they execute off whatever thread VLCKit called us on.
        self.vlcReadQueue.async { [weak self] in
            guard let self = self else { return }
            
            let height = player.videoSize.height
            let width = player.videoSize.width
            let audioTracksCount = player.trackDictionary(type: "audioTracks").count
            let activeAudioTrack = player.getSelectedTrackIndex(type: "audioTracks")
            let spuTracksCount = player.trackDictionary(type: "textTracks").count
            let activeSpuTrack = player.getSelectedTrackIndex(type: "textTracks")
            let duration = player.normalizedDuration
            let speed = player.rate
            let position = player.normalizedTime
            // SAFE here: state-change callback thread does not hold timer.lock
            let isPlaying = player.isPlaying
            let isSeekable = player.isSeekable
            
            // Cache isPlaying for use by time-event callbacks
            self.cachedIsPlaying = isPlaying
            
            var event: [String: Any] = ["event": "unknown"]
            switch newState {
            case .opening: event = ["event": "opening"]
            case .paused:
                self.cachedIsPlaying = false
                event = ["event": "paused"]
            case .stopped:
                self.cachedIsPlaying = false
                event = ["event": "stopped"]
            case .error: event = ["event": "error"]
            case .playing, .buffering:
                if newState == .playing { self.cachedIsPlaying = true }
                event = [
                    "event": newState == .playing ? "playing" : "buffering",
                    "height": height, "width": width, "speed": speed,
                    "duration": duration, "position": position,
                    "audioTracksCount": audioTracksCount, "activeAudioTrack": activeAudioTrack,
                    "spuTracksCount": spuTracksCount, "activeSpuTrack": activeSpuTrack,
                    "isPlaying": isPlaying, "isSeekable": isSeekable,
                ]
                if newState == .buffering { event["buffer"] = 100.0 }
            default: break
            }
            
            DispatchQueue.main.async {
                mediaEventSink(event)
            }
        }
    }
    
    @objc func mediaPlayer(_ player: VLCMediaPlayer, watchTime changed: Int64) {
        self.sendTimeEvent(player: player)
    }
    
    @objc func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let player = aNotification.object as? VLCMediaPlayer {
            self.sendTimeEvent(player: player)
        }
    }

    /// CRITICAL: This method may be called from VLCKit's timer thread which holds
    /// timer.lock (HandleWatchTimeUpdate/HandleWatchTimeOnSeek run inline because
    /// VLCEventsDefaultConfiguration.dispatchQueue returns nil).
    ///
    /// We MUST NOT call any libvlc_media_player_* function here because those
    /// need vlc_player_Lock, and calling vlc_player_Lock while timer.lock is
    /// held triggers:
    ///   Assertion failed: (!vlc_mutex_held(&player->timer.lock))
    ///
    /// Strategy: dispatch reads to vlcReadQueue.async. By the time our block
    /// executes, the timer callback has returned and released timer.lock.
    /// Use cachedIsPlaying instead of player.isPlaying.
    private func sendTimeEvent(player: VLCMediaPlayer) {
        guard let mediaEventSink = self.mediaEventSink else { return }
        
        // Snapshot the cached value BEFORE dispatching (safe atomic read)
        let isPlaying = self.cachedIsPlaying
        
        // Dispatch reads to the read queue — this ensures we're NOT on the
        // timer thread when we access player.time / player.media.length.
        // These properties use dispatch_sync(_timeChangeLockQueue) internally
        // which is safe as long as we're not on the timer thread.
        self.vlcReadQueue.async { [weak self] in
            guard self != nil else { return }
            
            let duration = player.normalizedDuration
            let position = player.normalizedTime
            
            DispatchQueue.main.async {
                mediaEventSink([
                    "event": "timeChanged",
                    "duration": duration,
                    "position": position,
                    "isPlaying": isPlaying,
                ])
            }
        }
    }
}

enum DataSourceType: Int { case ASSET = 0; case NETWORK = 1; case FILE = 2 }
enum HWAccellerationType: Int { case HW_ACCELERATION_AUTOMATIC = 0; case HW_ACCELERATION_DISABLED = 1; case HW_ACCELERATION_DECODING = 2; case HW_ACCELERATION_FULL = 3 }

extension VLCMediaPlayer {
    var isMicrosecond: Bool {
        let rawDuration = self.media?.length.value?.int64Value ?? 0
        let rawTime = self.time.value?.int64Value ?? 0
        return rawDuration > 20_000_000 || rawTime > 20_000_000
    }
    var normalizedDuration: Int {
        let raw = self.media?.length.value?.int64Value ?? 0
        return Int(isMicrosecond ? (raw / 1000) : raw)
    }
    var normalizedTime: Int {
        let raw = self.time.value?.int64Value ?? 0
        return Int(isMicrosecond ? (raw / 1000) : raw)
    }
    func trackDictionary(type: String) -> [Int: String] {
        var dict: [Int: String] = [:]
        if let tracks = (self as NSObject).value(forKey: type) as? [NSObject] {
            for (index, track) in tracks.enumerated() {
                dict[index] = track.value(forKey: "trackName") as? String ?? "Track \(index)"
            }
        }
        return dict
    }
    func getSelectedTrackIndex(type: String) -> Int {
        if let tracks = (self as NSObject).value(forKey: type) as? [NSObject] {
            return tracks.firstIndex { ($0.value(forKey: "selected") as? Bool) == true } ?? -1
        }
        return -1
    }
    func selectTrack(at index: Int, type: Int) {
        let listName: String
        switch type {
        case 0: listName = "audioTracks"
        case 1: listName = "videoTracks"
        case 2: listName = "textTracks"
        default: return
        }
        if index < 0 {
            let selector: String
            switch type {
            case 0: selector = "deselectAllAudioTracks"
            case 1: selector = "deselectAllVideoTracks"
            case 2: selector = "deselectAllTextTracks"
            default: return
            }
            let sel = Selector(selector)
            if self.responds(to: sel) { self.perform(sel) }
        } else if let tracks = (self as NSObject).value(forKey: listName) as? [NSObject], index < tracks.count {
            tracks[index].setValue(true, forKey: "selectedExclusively")
        }
    }
    func rendererServices() -> [String] {
        let renderers = VLCRendererDiscoverer.list()
        var services: [String] = []
        renderers?.forEach { description in services.append(description.name) }
        return services
    }
}
