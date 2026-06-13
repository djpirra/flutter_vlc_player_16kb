import Flutter
import Foundation
import MobileVLCKit
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
    
    // Subtitle font size as freetype-rel-fontsize (% of video height; VLC default = 5).
    // Stored so it can be re-injected each time a new media or subtitle track opens.
    private var subtitleRelSize: Int = 5
    
    // Tracks the SPU track ID last explicitly set via setSpuTrack.
    // nil  = user has never made an explicit selection this session →
    //        spuTrack falls back to VLC's real currentVideoSubTitleIndex so the
    //        modal correctly reflects what is already playing.
    // non-nil = use this optimistic value so Flutter's _waitForSubtitleActivation
    //        receives the intended index without waiting for VLC's (lagging) commit.
    // Reset to nil on every new media load so the real VLC state is re-read.
    private var lastSetSpuTrackId: Int32? = nil
    
    // Guards to prevent seek flooding (main-thread only)
    private var isSeekInFlight: Bool = false
    private var coalescedSeekTarget: Int64? = nil

    // Pending subtitle-size restore work item – cancelled when a newer resize
    // arrives so only the final tap in a rapid sequence fires the decoder restart.
    private var pendingSubtitleSizeRestore: DispatchWorkItem? = nil

    // Last external subtitle URL added via addSubtitleTrack.
    // Used by setSubtitleHeightScale to re-add the slave (forcing a fresh
    // subtitle ES decoder that reads the updated freetype-rel-fontsize option).
    // Reset on every new media load.
    private var lastExternalSubtitleUrl: URL? = nil
    
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
        
        // All stored properties are initialised — call super before using
        // `self` as a value (required by Swift's two-phase initialisation).
        super.init()
        
        self.mediaEventChannel.setStreamHandler(self.mediaEventChannelHandler)
        self.rendererEventChannel.setStreamHandler(self.rendererEventChannelHandler)
        self.vlcMediaPlayer.drawable = self.vlcView
        self.vlcMediaPlayer.delegate = self.mediaEventChannelHandler
        // Give the event handler a back-reference so it can read the optimistic
        // spuTrack (lastSetSpuTrackId) instead of VLC's raw currentVideoSubTitleIndex.
        self.mediaEventChannelHandler.vlcController = self
        
        // Note: minimalTimePeriod is not available in MobileVLCKit 3.x.
        // Time change notifications are received via the standard delegate/notification mechanism.
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
                self.vlcMediaPlayer.position = Float(clampedPercent)
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
        Int32(self.vlcMediaPlayer.subtitleTrackDictionary().count)
    }
    
    public var spuTracks: [Int: String] {
        self.vlcMediaPlayer.subtitleTrackDictionary()
    }
    
    public func setSpuTrack(spuTrackNumber: Int32) {
        let before = self.vlcMediaPlayer.currentVideoSubTitleIndex
        // Mirror the requested index immediately so spuTrack returns it without
        // waiting for VLC's internal state to commit (avoids Flutter timeout).
        lastSetSpuTrackId = spuTrackNumber
        if spuTrackNumber < 0 {
            // Disable subtitles: use -1 (VLCKit 3 sentinel)
            self.vlcMediaPlayer.currentVideoSubTitleIndex = -1
        } else {
            // Inject the stored font size before enabling so the subtitle ES
            // decoder initialises with the correct freetype option.
            self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")
            self.vlcMediaPlayer.selectSubtitleTrack(at: Int(spuTrackNumber))
        }
        let after = self.vlcMediaPlayer.currentVideoSubTitleIndex
        // Keep this single log per selection (not in the hot polling path).
        print("[VLC-SPU] setSpuTrack: requested=\(spuTrackNumber) vlcBefore=\(before) vlcAfter=\(after)")
    }
    
    public var spuTrack: Int32 {
        // NOTE: this getter is polled every 60 ms by Flutter — do NOT log here.
        //
        // When the user has made an explicit selection (lastSetSpuTrackId != nil)
        // return the optimistic value so Flutter's _waitForSubtitleActivation
        // receives a stable index immediately after setSpuTrack without waiting
        // for VLC's (sometimes lagging) currentVideoSubTitleIndex to commit.
        //
        // When no explicit selection has been made this session (nil) fall back
        // to VLC's real index so the modal shows the track that is *actually*
        // playing (e.g. a default track chosen by VLC on media open).
        if let lastSet = lastSetSpuTrackId {
            return lastSet
        }
        return self.vlcMediaPlayer.currentVideoSubTitleIndex
    }
    
    public func setSpuDelay(delay: Int) {
        self.vlcMediaPlayer.currentVideoSubTitleDelay = delay
    }
    
    public var spuDelay: Int {
        self.vlcMediaPlayer.currentVideoSubTitleDelay
    }
    
    public func addSubtitleTrack(uri: String, isSelected: Bool) {
        guard let url = URL(string: uri) else { return }
        // Apply the current font size before the external subtitle track opens.
        self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")
        // Store the URL so setSubtitleHeightScale can re-add this slave to force
        // a new subtitle ES decoder (the only reliable live resize in MobileVLCKit 3).
        lastExternalSubtitleUrl = url
        let tracksBefore = self.vlcMediaPlayer.videoSubTitlesNames ?? []
        print("[VLC-SPU] addSubtitleTrack: uri=\(url.lastPathComponent) enforce=\(isSelected) tracksBefore=\(tracksBefore)")
        self.vlcMediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: isSelected)
        // Log tracks after a short delay so VLC has time to register the new track.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let tracksAfter = self.vlcMediaPlayer.videoSubTitlesNames ?? []
            print("[VLC-SPU] addSubtitleTrack: tracksAfter(0.5s)=\(tracksAfter) currentIndex=\(self.vlcMediaPlayer.currentVideoSubTitleIndex)")
        }
    }
    
    public func setSubtitleHeightScale(scale: Float) {
        // MobileVLCKit 3 has no currentSubTitleFontScale (a VLC 4+ API).
        //
        // `freetype-rel-fontsize` is "font size as a percentage of video height".
        // VLC's built-in default is 5 (= 5 % of video height, which looks normal).
        // `scale` arrives from Dart as (userFontSize / 16.0), so scale = 1.0 maps
        // to the user's default size, 2.0 to double, etc.
        //
        // Dart sends `scale = userFontSize / 16.0`.  The initial VLC flag
        // (--freetype-rel-fontsize=N) is set directly to `userFontSize`, so
        // we must invert the same ratio here:  relSize = round(scale * 16).
        //   scale 0.5 ( 8 pt UI) → relSize  8   (small)
        //   scale 0.625(10 pt UI) → relSize 10   (matches the app default)
        //   scale 0.75 (12 pt UI) → relSize 12
        //   scale 1.0  (16 pt UI) → relSize 16   (large)
        //   scale 1.5  (24 pt UI) → relSize 24   (very large)
        //   scale 2.0  (32 pt UI) → relSize 32   (enormous)
        let relSize = max(1, Int((scale * 16.0).rounded()))
        subtitleRelSize = relSize

        // Persist as a per-item media option so every future subtitle decoder
        // open (on track selection or media re-open) picks up the correct size.
        self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(relSize)")

        // Cancel any previous pending restore so rapid slider taps only fire once.
        pendingSubtitleSizeRestore?.cancel()

        // ── Strategy ─────────────────────────────────────────────────────────
        // In MobileVLCKit 3, toggling currentVideoSubTitleIndex from -1 back to
        // a valid index only HIDES then SHOWS the existing subtitle renderer — it
        // does NOT restart the ES decoder, so it never re-reads freetype options.
        //
        // The only reliable way to make a live font-size change visible is to
        // force VLC to open a *new* subtitle ES decoder.
        //
        // • External subtitle (added via addPlaybackSlave / addSubtitleTrack):
        //   Re-add the same slave URL with enforce=true.  VLC creates a fresh
        //   decoder for that file that reads the updated freetype-rel-fontsize.
        //
        // • Embedded / unknown subtitle (IPTV embedded text, etc.):
        //   Fall back to the toggle approach with a longer delay.
        //   Note: bitmap subtitles (DVB, PGS, VobSub) are NOT rendered by
        //   FreeType at all – their size cannot be changed this way.
        // ─────────────────────────────────────────────────────────────────────

        if let externalUrl = lastExternalSubtitleUrl {
            let capturedRelSize = relSize
            print("[VLC-SPU] setSubtitleHeightScale (external): relSize=\(relSize) url=\(externalUrl.lastPathComponent)")

            // Briefly hide the current subtitle so there's no flash of old-size text.
            self.vlcMediaPlayer.currentVideoSubTitleIndex = -1

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Re-inject option immediately before the new decoder opens.
                self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(capturedRelSize)")

                // VLC deduplicates slave URLs — re-adding the exact same URL
                // switches to the existing decoder (opened with the OLD font size)
                // rather than creating a new one.  Appending a millisecond
                // timestamp makes VLC treat it as a fresh resource so it opens
                // a new FreeType decoder that picks up the updated font-size option.
                // Jellyfin ignores the unknown `_t` parameter and returns the
                // same SRT content.
                let ts = Int(Date().timeIntervalSince1970 * 1000)
                let bustUrl: URL
                if var comps = URLComponents(url: externalUrl, resolvingAgainstBaseURL: false) {
                    var items = comps.queryItems ?? []
                    items.removeAll { $0.name == "_t" }
                    items.append(URLQueryItem(name: "_t", value: "\(ts)"))
                    comps.queryItems = items
                    bustUrl = comps.url ?? externalUrl
                } else {
                    bustUrl = externalUrl
                }

                self.vlcMediaPlayer.addPlaybackSlave(bustUrl, type: .subtitle, enforce: true)
                print("[VLC-SPU] setSubtitleHeightScale (external): re-added slave relSize=\(capturedRelSize) vlcAfter=\(self.vlcMediaPlayer.currentVideoSubTitleIndex)")
            }
            pendingSubtitleSizeRestore = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
            return
        }

        // Embedded subtitle fallback: toggle track index with a longer delay.
        let trackToRestore: Int32
        let vlcRealIndex = self.vlcMediaPlayer.currentVideoSubTitleIndex
        if let last = lastSetSpuTrackId, last >= 0 {
            trackToRestore = last
        } else {
            guard vlcRealIndex >= 0 else {
                // No subtitle track active yet – the stored relSize will be applied
                // the next time a track is enabled via setSpuTrack or addSubtitleTrack.
                return
            }
            trackToRestore = vlcRealIndex
        }
        print("[VLC-SPU] setSubtitleHeightScale (embedded): relSize=\(relSize) vlcReal=\(vlcRealIndex) → toggle track \(trackToRestore)")

        self.vlcMediaPlayer.currentVideoSubTitleIndex = -1

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(relSize)")
            self.vlcMediaPlayer.currentVideoSubTitleIndex = trackToRestore
            print("[VLC-SPU] setSubtitleHeightScale (embedded): restored trackId=\(trackToRestore) vlcAfter=\(self.vlcMediaPlayer.currentVideoSubTitleIndex)")
        }
        pendingSubtitleSizeRestore = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    public var audioTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.audioTrackDictionary().count)
    }
    
    public var audioTracks: [Int: String] {
        self.vlcMediaPlayer.audioTrackDictionary()
    }
    
    public func setAudioTrack(audioTrackNumber: Int32) {
        self.vlcMediaPlayer.selectAudioTrack(at: Int(audioTrackNumber))
    }
    
    public var audioTrack: Int32 {
        Int32(self.vlcMediaPlayer.selectedAudioTrackIndex)
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
        Int32(self.vlcMediaPlayer.videoTrackDictionary().count)
    }
    
    public var videoTracks: [Int: String] {
        self.vlcMediaPlayer.videoTrackDictionary()
    }
    
    public func setVideoTrack(videoTrackNumber: Int32) {
        self.vlcMediaPlayer.selectVideoTrack(at: Int(videoTrackNumber))
    }
    
    public var videoTrack: Int32 {
        Int32(self.vlcMediaPlayer.selectedVideoTrackIndex)
    }
    
    public func setVideoScale(scale: Float) {
        self.vlcMediaPlayer.scaleFactor = scale
    }
    
    public var videoScale: Float {
        self.vlcMediaPlayer.scaleFactor
    }
    
    public func setVideoAspectRatio(aspectRatio: String) {
        // MobileVLCKit 3: videoAspectRatio is UnsafeMutablePointer<CChar>?
        // strdup() allocates a C string that VLCKit will own/free.
        self.vlcMediaPlayer.videoAspectRatio = strdup(aspectRatio)
    }
    
    public var videoAspectRatio: String {
        guard let ptr = self.vlcMediaPlayer.videoAspectRatio else { return "" }
        return String(cString: ptr)
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
    
    func updatePlaybackCaches(position: Int, duration: Int, isPlaying: Bool) {
        self.lastKnownPosition = position
        if duration > 0 {
            self.lastKnownDuration = duration
        }
        self.lastKnownIsPlaying = isPlaying
    }

    public func dispose() {
        // Stop VLC delegate callbacks immediately so timer threads can't enqueue
        // new `vlc_event_read` work while we're tearing down.
        self.vlcMediaPlayer.delegate = nil
        self.mediaEventChannelHandler.prepareForDisposeDrainingReads()

        self.mediaEventChannel.setStreamHandler(nil)
        self.rendererEventChannel.setStreamHandler(nil)
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        self.vlcMediaPlayer.stop()
        self.mediaEventChannelHandler.player = nil
    }
    
    func setMediaPlayerUrl(uri: String, isAssetUrl: Bool, autoPlay: Bool, hwAcc: Int, options: [String]) {
        // Reset per-media state so values from a previous media item don't bleed
        // into the new one.
        lastSetSpuTrackId = nil
        lastExternalSubtitleUrl = nil
        pendingSubtitleSizeRestore?.cancel()
        pendingSubtitleSizeRestore = nil
        // Block and drain time/state read work while stop/media swap runs so
        // vlcReadQueue never touches VLCMediaPlayer after libvlc teardown starts.
        self.mediaEventChannelHandler.beginPlaybackMutation()
        defer { self.mediaEventChannelHandler.endPlaybackMutation() }
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
        
        // Bake the current subtitle font size into every new media item so the
        // freetype renderer reads the correct value when it first initialises
        // (before any setSubtitleHeightScale call can arrive from Dart).
        media.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")
        
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
    /// Back-reference to the owning controller so we can read the OPTIMISTIC
    /// spuTrack (lastSetSpuTrackId) rather than VLC's raw currentVideoSubTitleIndex,
    /// which keeps the event stream consistent with the Pigeon getter.
    weak var vlcController: VLCViewController?
    
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
    /// Duration in milliseconds, refreshed from media.length on state changes.
    private var cachedDurationMs: Int = 0
    /// True while stop/media swap/dispose is in progress; suppresses new reads.
    private var isPlaybackMutationInProgress: Bool = false
    
    override init() {
        super.init()
    }

    /// Refresh duration cache from `media.length` only — never touch `player.time`
    /// here because VLCTime can be torn down while libvlc updates the clock.
    private func refreshDurationCache(from player: VLCMediaPlayer) {
        let rawLength = player.media?.length.value?.int64Value ?? 0
        guard rawLength > 0 else { return }
        let isMicro = rawLength > 20_000_000
        cachedDurationMs = Int(isMicro ? (rawLength / 1000) : rawLength)
    }

    /// Derive position ms from the float slider (0…1) and cached duration.
    /// Avoids reading `player.time`, which races with libvlc on background queues.
    private func positionMs(from player: VLCMediaPlayer) -> Int {
        guard cachedDurationMs > 0 else { return 0 }
        let fraction = max(0, min(1, player.position))
        return Int((Float(cachedDurationMs) * fraction).rounded())
    }

    private func deliverMediaEvent(_ event: [String: Any]) {
        guard let mediaEventSink = self.mediaEventSink else { return }
        if Thread.isMainThread {
            mediaEventSink(event)
        } else {
            DispatchQueue.main.async {
                mediaEventSink(event)
            }
        }
    }
    
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.mediaEventSink = events
        return nil
    }
    
    func onCancel(withArguments _: Any?) -> FlutterError? {
        self.mediaEventSink = nil
        return nil
    }

    /// Blocks until queued read work on vlc_event_read completes. Safe to call
    /// before `stop`/media teardown so VLCMediaPlayer accessors are never hit
    /// while libvlc is tearing down another thread still posting time-change events.
    func drainPlaybackPropertyReadQueueForSafeMutation() {
        vlcReadQueue.sync { /* drain */ }
    }

    /// Call before `stop`/media swap: suppresses new reads and drains in-flight work.
    func beginPlaybackMutation() {
        isPlaybackMutationInProgress = true
        cachedDurationMs = 0
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
    }

    /// Call after `stop`/media swap: drains stop-triggered reads, then re-enables events.
    func endPlaybackMutation() {
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
        isPlaybackMutationInProgress = false
    }

    /// Call while disposing or before VLCMediaPlayer teardown: clears the Flutter
    /// sink first (so `sendTimeEvent` stops scheduling reads), then drains the
    /// read queue before native `stop`/deallocation proceeds.
    func prepareForDisposeDrainingReads() {
        isPlaybackMutationInProgress = true
        cachedDurationMs = 0
        self.mediaEventSink = nil
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
    }
    
    // mediaPlayerLengthChanged(:Int64) was a VLCKit 4 delegate method.
    // In MobileVLCKit 3, duration changes come through mediaPlayerTimeChanged notification
    // and are read from player.media?.length inside sendTimeEvent.
    
    @objc func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard self.mediaEventSink != nil,
              self.player != nil,
              !isPlaybackMutationInProgress else { return }
        
        // State-change callbacks (HandleMediaInstanceStateChanged) dispatch through
        // VLCEventsHandler. With VLCEventsDefaultConfiguration (dispatchQueue=nil),
        // they run inline on the libvlc event thread. This thread does NOT hold
        // timer.lock, so calling player.isPlaying here is safe.
        //
        // However, to be extra safe, dispatch all reads to vlcReadQueue (async)
        // so they execute off whatever thread VLCKit called us on.
        self.vlcReadQueue.async { [weak self] in
            guard let self = self,
                  self.mediaEventSink != nil,
                  !self.isPlaybackMutationInProgress,
                  let player = self.player else { return }
            
            let height = player.videoSize.height
            let width = player.videoSize.width
            let audioTracksCount = player.audioTrackDictionary().count
            let activeAudioTrack = player.selectedAudioTrackIndex
            let spuTracksCount = player.subtitleTrackDictionary().count
            // Use the optimistic lastSetSpuTrackId (via vlcController.spuTrack) so that
            // state-change events are consistent with the Pigeon getSpuTrack() getter.
            // Without this, a playing/buffering event immediately after setSpuTrack would
            // send the wrong raw VLC index, resetting Flutter's selected-track indicator.
            let activeSpuTrack = self.vlcController.map { Int($0.spuTrack) }
                ?? player.selectedSubtitleTrackIndex
            self.refreshDurationCache(from: player)
            let duration = self.cachedDurationMs
            let speed = player.rate
            let position = self.positionMs(from: player)
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
            
            self.vlcController?.updatePlaybackCaches(
                position: position,
                duration: duration,
                isPlaying: isPlaying
            )
            self.deliverMediaEvent(event)
        }
    }
    
    // mediaPlayer(_:watchTime:) is a VLCKit 4 delegate method — not available in MobileVLCKit 3.
    // Time updates in MobileVLCKit 3 come via the mediaPlayerTimeChanged NSNotification delegate.
    
    @objc func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let notificationPlayer = aNotification.object as? VLCMediaPlayer,
              notificationPlayer === self.player else { return }
        self.sendTimeEvent()
    }

    /// Called directly from `mediaPlayerTimeChanged` while VLCKit's time snapshot
    /// is still valid. Never defer to vlcReadQueue — deferred reads of
    /// `player.time` / `VLCTime.value` race with the next tick and can SIGSEGV.
    /// Use `player.position` (float 0…1) × cached duration instead of `player.time`.
    private func sendTimeEvent() {
        guard self.mediaEventSink != nil,
              !isPlaybackMutationInProgress,
              let player = self.player else { return }
        
        let isPlaying = self.cachedIsPlaying
        if cachedDurationMs <= 0 {
            refreshDurationCache(from: player)
        }
        let duration = cachedDurationMs
        let position = positionMs(from: player)
        
        vlcController?.updatePlaybackCaches(
            position: position,
            duration: duration,
            isPlaying: isPlaying
        )
        deliverMediaEvent([
            "event": "timeChanged",
            "duration": duration,
            "position": position,
            "isPlaying": isPlaying,
        ])
    }
}

enum DataSourceType: Int { case ASSET = 0; case NETWORK = 1; case FILE = 2 }
enum HWAccellerationType: Int { case HW_ACCELERATION_AUTOMATIC = 0; case HW_ACCELERATION_DISABLED = 1; case HW_ACCELERATION_DECODING = 2; case HW_ACCELERATION_FULL = 3 }

// MARK: - MobileVLCKit 3.x compatibility extensions
// MobileVLCKit 3 exposes tracks via typed arrays (audioTrackNames, videoSubTitlesNames, etc.)
// rather than the KVO-based generic trackDictionary used in VLCKit 4.
extension VLCMediaPlayer {
    /// True when `media.length` is expressed in microseconds (VLC live/TS streams).
    var lengthUsesMicroseconds: Bool {
        let rawDuration = self.media?.length.value?.int64Value ?? 0
        return rawDuration > 20_000_000
    }
    var normalizedDuration: Int {
        let raw = self.media?.length.value?.int64Value ?? 0
        guard raw > 0 else { return 0 }
        return Int(lengthUsesMicroseconds ? (raw / 1000) : raw)
    }
    var normalizedTime: Int {
        let raw = self.time.value?.int64Value ?? 0
        guard raw > 0 else { return 0 }
        let isMicro = lengthUsesMicroseconds || raw > 20_000_000
        return Int(isMicro ? (raw / 1000) : raw)
    }

    // MARK: Track dictionaries (MobileVLCKit 3 API)

    /// Returns { index: name } for audio tracks. Index is the sequential position
    /// used by currentAudioTrackIndex to select a track.
    func audioTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names = self.audioTrackNames ?? []
        for (i, name) in names.enumerated() {
            dict[i] = (name as? String) ?? "Audio \(i)"
        }
        return dict
    }

    /// Returns { internalId: name } for subtitle tracks.
    ///
    /// Keys are the **VLC internal track IDs** from `videoSubTitlesIndexes`.
    /// `currentVideoSubTitleIndex` / `libvlc_video_set_spu` uses these IDs directly —
    /// NOT the positional indices in `videoSubTitlesNames`.  Using positional indices
    /// caused an off-by-one where selecting "pt-PT" (positional 4) would activate
    /// the track whose internal ID is 4, which is actually "Persian" (positional 3).
    /// -1 is the disable sentinel and is always excluded.
    func subtitleTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names   = self.videoSubTitlesNames   ?? []
        let indices = self.videoSubTitlesIndexes ?? []
        for (i, name) in names.enumerated() {
            let label = (name as? String) ?? ""
            if label.lowercased() == "disable" || label.isEmpty { continue }
            // Use the actual VLC internal ID if available, otherwise fall back to
            // the positional index (shouldn't happen in practice).
            let internalId: Int
            if i < indices.count, let n = indices[i] as? NSNumber {
                internalId = n.intValue
            } else {
                internalId = i
            }
            if internalId < 0 { continue } // skip the "Disabled" sentinel (-1)
            dict[internalId] = label
        }
        return dict
    }

    /// Returns { index: name } for video tracks.
    func videoTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names = self.videoTrackNames ?? []
        for (i, name) in names.enumerated() {
            dict[i] = (name as? String) ?? "Video \(i)"
        }
        return dict
    }

    // MARK: Selected track indices (MobileVLCKit 3 API)

    var selectedAudioTrackIndex: Int {
        return Int(self.currentAudioTrackIndex)
    }

    var selectedSubtitleTrackIndex: Int {
        let idx = Int(self.currentVideoSubTitleIndex)
        // VLCKit 3 returns -1 when subtitles are disabled
        return idx
    }

    var selectedVideoTrackIndex: Int {
        return Int(self.currentVideoTrackIndex)
    }

    // MARK: Track selection (MobileVLCKit 3 API)

    func selectAudioTrack(at index: Int) {
        self.currentAudioTrackIndex = Int32(index)
    }

    func selectSubtitleTrack(at index: Int) {
        self.currentVideoSubTitleIndex = Int32(index)
    }

    func selectVideoTrack(at index: Int) {
        self.currentVideoTrackIndex = Int32(index)
    }

    func rendererServices() -> [String] {
        let renderers = VLCRendererDiscoverer.list()
        var services: [String] = []
        renderers?.forEach { description in services.append(description.name) }
        return services
    }
}
