// Meet for Me: a small SwiftUI front end for listener.py.
// The app starts/stops the Python engine, shows the live transcript and
// alerts, and edits the settings (names, notes, audio device, model).
import AppKit
import AVFoundation
import CoreAudio
import SwiftUI
import UserNotifications

// MARK: - Models

struct TranscriptLine: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let mention: Bool
}

struct AlertItem: Identifiable {
    let id = UUID()
    let time: String
    let question: String
    let answer: String
    let confidence: String
    let sources: [String]
    let file: String
}

enum EngineState: Equatable {
    case stopped, starting, loading, listening, failed(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .loading: return "Loading speech model…"
        case .listening: return "Listening"
        case .failed(let m): return m
        }
    }

    var color: Color {
        switch self {
        case .listening: return .green
        case .starting, .loading: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var isRunning: Bool {
        switch self {
        case .starting, .loading, .listening: return true
        default: return false
        }
    }
}

// MARK: - Audio output check

/// Name of the Mac's current sound output device (where browser Zoom plays).
func defaultOutputDeviceName() -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                     &size, &dev) == noErr else { return nil }
    addr.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr,
          let n = name?.takeRetainedValue() else { return nil }
    return n as String
}

func outputReachesBlackHole(_ name: String?) -> Bool {
    guard let n = name?.lowercased() else { return true }
    return n.contains("multi-output") || n.contains("blackhole")
}

// MARK: - Per-app audio capture (Core Audio process taps, macOS 14.4+)

/// Apps the user can pick. Matched by bundle-ID prefix, so helper processes (Chrome's audio
/// service, Zoom's CptHost…) are included.
struct CaptureApp: Identifiable, Hashable {
    let id: String      // bundle-ID prefix
    let name: String
    static let known: [CaptureApp] = [
        CaptureApp(id: "us.zoom", name: "Zoom"),
        CaptureApp(id: "com.microsoft.teams", name: "Microsoft Teams"),
        CaptureApp(id: "com.cisco.webex", name: "Webex"),
        CaptureApp(id: "com.tinyspeck.slackmacgap", name: "Slack (huddles)"),
        CaptureApp(id: "com.google.Chrome", name: "Google Chrome"),
        CaptureApp(id: "com.brave.Browser", name: "Brave"),
        CaptureApp(id: "com.microsoft.edgemac", name: "Microsoft Edge"),
        CaptureApp(id: "company.thebrowser", name: "Arc"),
        CaptureApp(id: "org.mozilla.firefox", name: "Firefox"),
        CaptureApp(id: "com.apple.WebKit", name: "Safari (all WebKit apps)"),
        CaptureApp(id: "com.apple.QuickTimePlayerX", name: "QuickTime Player (for testing)"),
    ]
    static let defaults = ["us.zoom", "com.microsoft.teams", "com.cisco.webex", "com.google.Chrome"]
}

enum AudioProcesses {
    struct Info { let object: AudioObjectID; let bundleID: String; let playing: Bool }

    static func all() -> [Info] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            let bundle = AudioDevices.cfProperty(id, kAudioProcessPropertyBundleID) as? String ?? ""
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &running)
            return Info(object: id, bundleID: bundle, playing: running != 0)
        }
    }

    static func matching(_ prefixes: [String]) -> [Info] {
        all().filter { p in prefixes.contains { p.bundleID.lowercased().hasPrefix($0.lowercased()) } }
    }
}

/// Taps the chosen apps' audio, mixes it to mono 16 kHz float32 and hands it to `onAudio`.
final class AppAudioCapture {
    private let prefixes: [String]
    private let onAudio: (Data) -> Void
    private let onSources: ([String]) -> Void
    var onReport: ((String) -> Void)?
    var logURL: URL?
    private var framesIn = 0, bytesOut = 0, peak: Float = 0, lastStats = Date()
    private let queue = DispatchQueue(label: "meetforme.capture")      // control: build / teardown
    private let ioQueue = DispatchQueue(label: "meetforme.capture.io") // audio callbacks only
    private let statsLock = NSLock()
    private var silentSince: Date? = nil
    private var lastRebuild = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapped: [AudioObjectID] = []
    private var srcRate: Double = 48000
    private var pending: [Float] = []
    private var pos: Double = 0

    init(prefixes: [String], onAudio: @escaping (Data) -> Void, onSources: @escaping ([String]) -> Void) {
        self.prefixes = prefixes
        self.onAudio = onAudio
        self.onSources = onSources
    }

    func start() {
        queue.async { self.update() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.update() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { teardown() }
    }

    /// Rebuild the tap when the set of matching app processes changes (e.g. you join a call).
    private func update() {
        let procs = AudioProcesses.matching(prefixes)
        let ids = procs.map(\.object).sorted()
        onSources(Array(Set(procs.map(\.bundleID))).sorted())
        if Date().timeIntervalSince(lastStats) >= 3 {
            statsLock.lock()
            let (fi, bo, pk) = (framesIn, bytesOut, peak)
            framesIn = 0; bytesOut = 0; peak = 0
            statsLock.unlock()
            lastStats = Date()
            report("stats: matching=\(procs.map { $0.bundleID + ($0.playing ? "*" : "") }) tapped=\(tapped.count) agg=\(aggID) framesIn=\(fi) bytesOut=\(bo) peak=\(pk)")
            // Watchdog: a tapped app is playing but we get exact digital silence (e.g. the
            // audio-recording permission was granted after the tap was made) -> rebuild.
            let anyPlaying = procs.contains { $0.playing && tapped.contains($0.object) }
            if anyPlaying && fi > 0 && pk == 0 {
                if silentSince == nil { silentSince = Date() }
                if let since = silentSince, Date().timeIntervalSince(since) > 15,
                   Date().timeIntervalSince(lastRebuild) > 30 {
                    report("only silence while an app is playing: rebuilding the capture")
                    silentSince = nil
                    teardown()
                }
            } else {
                silentSince = nil
            }
        }
        if ids == tapped && (ids.isEmpty || aggID != kAudioObjectUnknown) { return }
        teardown()
        tapped = ids
        lastRebuild = Date()
        if !ids.isEmpty { build(ids) }
    }

    private func build(_ processes: [AudioObjectID]) {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "Meet for Me"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted       // you keep hearing the meeting normally
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr else { report("could not create process tap (error \(tapStatus))"); return }
        tapID = tap

        // Tap format (sample rate, channels)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 {
            srcRate = fmt.mSampleRate
        }

        // A private aggregate device that contains only the tap, clocked by a real output device.
        // If the Mac output is itself an aggregate (e.g. a Multi-Output Device), macOS refuses to
        // nest it, so use its first sub-device (your speakers/headphones) instead.
        var outputUID = AudioDevices.defaultOutput().map(AudioDevices.uid) ?? ""
        if let out = AudioDevices.defaultOutput(), AudioDevices.isAggregate(out) {
            let subs = AudioDevices.subDeviceUIDs(out).filter { !$0.lowercased().contains("blackhole") }
            if let first = subs.first ?? AudioDevices.subDeviceUIDs(out).first { outputUID = first }
        }
        report("tap \(tap) for \(processes.count) process(es), \(Int(srcRate)) Hz, clock device \(outputUID)")
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meet for Me Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard aggStatus == noErr else { report("could not create capture device (error \(aggStatus))"); teardown(); return }
        aggID = agg

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else { report("IOProc failed (error \(status))"); teardown(); return }
        procID = proc
        let startStatus = AudioDeviceStart(agg, proc)
        if startStatus != noErr { report("start failed (error \(startStatus))"); teardown() } else { report("capturing") }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        var mono: [Float] = []
        if list.count == 1 {
            let b = list[0]
            let ch = max(Int(b.mNumberChannels), 1)
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size / ch
            guard let p = b.mData?.assumingMemoryBound(to: Float.self), n > 0 else { return }
            mono.reserveCapacity(n)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<ch { sum += p[i * ch + c] }
                mono.append(sum / Float(ch))
            }
        } else {  // non-interleaved: one buffer per channel
            let n = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: n)
            for b in list {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<min(n, Int(b.mDataByteSize) / 4) { mono[i] += p[i] / Float(list.count) }
            }
        }
        var localPeak: Float = 0
        for v in mono where abs(v) > localPeak { localPeak = abs(v) }
        statsLock.lock()
        framesIn += mono.count
        if localPeak > peak { peak = localPeak }
        statsLock.unlock()
        // Linear resample to 16 kHz.
        pending.append(contentsOf: mono)
        let step = srcRate / 16000
        var out: [Float] = []
        out.reserveCapacity(Int(Double(pending.count) / step) + 1)
        while pos + 1 < Double(pending.count) {
            let i = Int(pos)
            let f = Float(pos - Double(i))
            out.append(pending[i] * (1 - f) + pending[i + 1] * f)
            pos += step
        }
        let used = min(Int(pos), pending.count)
        pending.removeFirst(used)
        pos -= Double(used)
        if !out.isEmpty {
            statsLock.lock(); bytesOut += out.count * 4; statsLock.unlock()
            onAudio(out.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    private func report(_ msg: String) {
        onReport?(msg)
        guard let logURL else { return }
        let line = "\(Date()) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private func teardown() {
        if aggID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggID, procID)
                AudioDeviceDestroyIOProcID(aggID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        tapped = []
        pending.removeAll()
        pos = 0
    }
}

// MARK: - config.json helpers

enum ConfigFile {
    static func read(_ url: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return obj
    }

    static func update(_ url: URL, _ changes: [String: Any]) {
        var cfg = read(url)
        for (k, v) in changes { cfg[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: cfg,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: url)
        }
    }

    /// "apps" (per-app capture, default) or "blackhole".
    static func audioSource(_ cfg: [String: Any]) -> String { cfg["audio_source"] as? String ?? "apps" }
    static func captureApps(_ cfg: [String: Any]) -> [String] { cfg["capture_apps"] as? [String] ?? CaptureApp.defaults }
}

// MARK: - Setup checks (BlackHole, Multi-Output, output, permissions, engine)

enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func cfProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> CFTypeRef? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    static func name(_ id: AudioDeviceID) -> String { cfProperty(id, kAudioObjectPropertyName) as? String ?? "" }
    static func uid(_ id: AudioDeviceID) -> String { cfProperty(id, kAudioDevicePropertyDeviceUID) as? String ?? "" }
    static func subDeviceUIDs(_ id: AudioDeviceID) -> [String] {
        cfProperty(id, kAudioAggregateDevicePropertyFullSubDeviceList) as? [String] ?? []
    }

    static func isAggregate(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeAggregate
    }

    static func defaultOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &size, &dev) == noErr else { return nil }
        return dev
    }
}

struct SetupCheck: Identifiable {
    enum ID: String { case name, capture, blackhole, multiOutput, output, microphone, notifications, engine, claude }
    let id: ID
    let title: String
    let ok: Bool
    let detail: String
    var optional = false   // "recommended" instead of "required"
}

@MainActor
final class SetupChecker: ObservableObject {
    @Published var checks: [SetupCheck] = []
    @Published var notificationsAllowed: Bool? = nil

    var needSetup: [SetupCheck] { checks.filter { !$0.ok && !$0.optional } }

    func refresh(_ engine: Engine) {
        var out: [SetupCheck] = []

        // Name
        var names: [String] = []
        if let d = try? Data(contentsOf: engine.configURL),
           let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            names = cfg["my_names"] as? [String] ?? []
        }
        out.append(SetupCheck(id: .name, title: "Your name", ok: !names.isEmpty,
                              detail: names.isEmpty ? "Not set: the app can't tell when you're called."
                                                    : "Listening for: " + names.joined(separator: ", ")))

        // Audio source
        let cfg = ConfigFile.read(engine.configURL)
        let appMode = ConfigFile.audioSource(cfg) == "apps"
        if appMode {
            let chosen = ConfigFile.captureApps(cfg)
            let names = CaptureApp.known.filter { chosen.contains($0.id) }.map(\.name)
            let live = AudioProcesses.matching(chosen).filter(\.playing).map(\.bundleID)
            out.append(SetupCheck(id: .capture, title: "Meeting app capture", ok: !chosen.isEmpty,
                                  detail: chosen.isEmpty ? "No app selected."
                                  : "Listening to: " + names.joined(separator: ", ")
                                    + (live.isEmpty ? ". None is playing audio right now." : ". Playing now: " + live.joined(separator: ", ")) + "."
                                    + " macOS asks once to allow recording app audio."))
        }

        // Audio devices (BlackHole mode only)
        let devices = AudioDevices.all()
        let blackhole = devices.first { AudioDevices.name($0).lowercased().contains("blackhole") }
        if !appMode {
        out.append(SetupCheck(id: .blackhole, title: "BlackHole installed", ok: blackhole != nil,
                              detail: blackhole != nil ? "Found \u{201C}\(AudioDevices.name(blackhole!))\u{201D}."
                                                       : "Virtual audio device not found."))
        let bhUID = blackhole.map(AudioDevices.uid) ?? "-"
        let multi = devices.first { AudioDevices.isAggregate($0) && AudioDevices.subDeviceUIDs($0).contains(bhUID) }
        let anyMulti = devices.first { AudioDevices.name($0).lowercased().contains("multi-output") }
        let multiDetail: String
        if let multi {
            multiDetail = "\u{201C}\(AudioDevices.name(multi))\u{201D} includes BlackHole."
        } else if anyMulti != nil {
            multiDetail = "A Multi-Output Device exists but BlackHole isn't ticked in it."
        } else {
            multiDetail = "No Multi-Output Device with BlackHole yet."
        }
        out.append(SetupCheck(id: .multiOutput, title: "Multi-Output Device", ok: multi != nil, detail: multiDetail))

        let current = AudioDevices.defaultOutput()
        let outOK = current != nil && (current == multi || current == blackhole)
        out.append(SetupCheck(id: .output, title: "Mac sound output", ok: outOK,
                              detail: outOK ? "Set to \u{201C}\(AudioDevices.name(current!))\u{201D}."
                              : "Is \u{201C}\(current.map(AudioDevices.name) ?? "unknown")\u{201D}. Needed for meetings in a browser; "
                                + "for the Zoom/Teams app set its Speaker to Multi-Output Device instead.",
                              optional: true))
        }

        // Permissions
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if !appMode {
        out.append(SetupCheck(id: .microphone, title: "Microphone access", ok: mic == .authorized,
                              detail: mic == .authorized ? "Allowed (used only to read BlackHole)."
                              : mic == .notDetermined ? "Not asked yet." : "Denied: allow it in System Settings."))
        }
        let notif = notificationsAllowed
        out.append(SetupCheck(id: .notifications, title: "Notifications", ok: notif == true,
                              detail: notif == true ? "Allowed."
                              : "Not allowed: you'll still get the floating alert cards.",
                              optional: true))

        // Engine + Claude
        let missing = engine.engineMissing
        out.append(SetupCheck(id: .engine, title: "Listener engine", ok: missing == nil,
                              detail: missing ?? "Found in \(engine.folderPath)."))
        let claude = Engine.environment["PATH", default: ""].split(separator: ":")
            .map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        out.append(SetupCheck(id: .claude, title: "Claude Code CLI", ok: claude != nil,
                              detail: claude != nil ? "Found at \(claude!)."
                                                    : "`claude` not found: drafted answers and chat need it."))
        checks = out

        UNUserNotificationCenter.current().getNotificationSettings { s in
            let allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in
                if self.notificationsAllowed != allowed {
                    self.notificationsAllowed = allowed
                    self.refresh(engine)
                }
            }
        }
    }
}

struct CopyCommand: View {
    let command: String
    var body: some View {
        HStack {
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

struct SetupRow: View {
    let check: SetupCheck
    @ObservedObject var checker: SetupChecker
    let engine: Engine
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: check.ok ? "checkmark.circle.fill"
                      : (check.optional ? "exclamationmark.circle" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(check.ok ? .green : (check.optional ? .secondary : .orange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title).font(.headline)
                    Text(check.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(check.ok ? "Done" : (check.optional ? "Recommended" : "Need setup"))
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((check.ok ? Color.green : (check.optional ? Color.gray : Color.orange)).opacity(0.18)))
                if !check.ok {
                    Button(expanded ? "Hide" : "How to fix") { expanded.toggle() }
                        .buttonStyle(.borderless)
                }
            }
            if expanded && !check.ok { fix.padding(.leading, 28) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var fix: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch check.id {
            case .name:
                Text("Go to the previous step of the guide, or Settings → Your name.")
            case .capture:
                Text("Pick your meeting apps in Settings → Audio source (or step 3 of the setup guide). When you first start listening, macOS asks to allow recording app audio: click Allow.")
                Button("Open Privacy → Screen & System Audio Recording") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            case .blackhole:
                Text("1. Run this in Terminal (it asks for your Mac password):")
                CopyCommand(command: "brew install --cask blackhole-2ch")
                Text("2. Then restart your Mac, or run:")
                CopyCommand(command: "sudo killall coreaudiod")
                Text("No Homebrew? Install it from brew.sh first.").font(.caption).foregroundStyle(.secondary)
            case .multiOutput:
                Text("1. Open Audio MIDI Setup.\n2. Click + (bottom left) → Create Multi-Output Device.\n3. Tick your speakers or headphones first, then BlackHole 2ch.\n4. Tick Drift Correction on the BlackHole row.")
                Button("Open Audio MIDI Setup") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                }
            case .output:
                Text("Meeting in a browser (Google Meet, Zoom/Teams on the web): set the Mac's Sound → Output to Multi-Output Device.\nZoom or Teams app: in the app's audio settings, set Speaker to Multi-Output Device (then this item can stay as is).")
                Button("Open Sound Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
            case .microphone:
                Text("The app reads meeting audio from BlackHole, which macOS treats as a microphone.")
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    Button("Allow microphone access") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in checker.refresh(engine) }
                        }
                    }
                } else {
                    Button("Open Privacy → Microphone") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            case .notifications:
                Button("Allow notifications") {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                        Task { @MainActor in checker.notificationsAllowed = nil; checker.refresh(engine) }
                    }
                }
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            case .engine:
                Text("Install the engine (see README), then point the app to its folder in Settings → Engine:")
                CopyCommand(command: "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt")
            case .claude:
                Text("Install Claude Code and log in, then reopen this check:")
                CopyCommand(command: "npm install -g @anthropic-ai/claude-code && claude")
            }
        }
        .font(.callout)
    }
}

/// The checklist, used in the setup guide and in the Setup tab. Re-checks every 2 seconds.
struct SetupChecklist: View {
    @ObservedObject var checker: SetupChecker
    let engine: Engine
    var only: [SetupCheck.ID]? = nil
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(checker.checks.filter { only == nil || only!.contains($0.id) }) { c in
                SetupRow(check: c, checker: checker, engine: engine)
                Divider()
            }
        }
        .onAppear { checker.refresh(engine) }
        .onReceive(timer) { _ in checker.refresh(engine) }
    }
}

struct SetupTab: View {
    @ObservedObject var engine: Engine
    @ObservedObject var checker: SetupChecker
    let openGuide: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Setup check").font(.title2.bold())
                        Text(checker.needSetup.isEmpty ? "Everything required is set up."
                             : "\(checker.needSetup.count) item(s) need setup.")
                            .foregroundStyle(checker.needSetup.isEmpty ? .green : .orange)
                    }
                    Spacer()
                    Button("Open setup guide…", action: openGuide)
                }
                SetupChecklist(checker: checker, engine: engine)
            }
            .padding(16)
        }
    }
}

/// First-launch guide: welcome → your name → audio & permissions → done.
struct OnboardingView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var checker: SetupChecker
    let finish: () -> Void
    @StateObject private var s = SettingsModel()
    @State private var step = 0
    private let titles = ["Welcome", "Your name", "Audio setup", "Permissions", "All set"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .padding([.horizontal, .top], 20)
            Text("Step \(step + 1) of \(titles.count): \(titles[step])")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < titles.count - 1 {
                    Button("Skip setup") { finish() }.buttonStyle(.borderless)
                }
                Button(step == titles.count - 1 ? "Start using Meet for Me" : "Continue") { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && s.names.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear { s.load(from: engine); checker.refresh(engine) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            Text("Welcome to Meet for Me").font(.largeTitle.bold())
            Text("Meet for Me listens to your meetings (Zoom, Google Meet, Teams) on this Mac, transcribes them locally, and alerts you when someone asks **you** a question, with a drafted answer based on what was said in the meeting.")
            Label("Audio is transcribed on this Mac. Only the relevant transcript is sent to Claude to draft answers and for chat.", systemImage: "lock.shield")
            Label("Recording colleagues may need their consent. Tell people when you use it.", systemImage: "exclamationmark.bubble")
            Text("Setup takes about 5 minutes: your name, then a one-time audio setup.").foregroundStyle(.secondary)
        case 1:
            Text("What do people call you?").font(.title.bold())
            Text("The app alerts you when it hears one of these names. Write Vietnamese names **with tone marks**: Hiếu (the name) is different from hiểu (to understand), so the app won't confuse them.")
            TextField("Your name(s), comma-separated", text: $s.names, prompt: Text("Hiếu, Trung Hiếu"))
                .textFieldStyle(.roundedBorder)
            TextField("Other names (English name, nickname), optional", text: $s.aliases, prompt: Text("Hugh, Henry"))
                .textFieldStyle(.roundedBorder)
            TextField("Project words Whisper should spell right, optional", text: $s.jargon, prompt: Text("API, deploy, staging, sprint"))
                .textFieldStyle(.roundedBorder)
            Text("Tips: if your name is also a pronoun (Anh, Em, Chị), use your full given name (Đức Anh). If a colleague has the same name, use your full name (Trung Hiếu). Versions without tone marks are added automatically.")
                .font(.callout).foregroundStyle(.secondary)
            if !s.message.isEmpty {
                Text(s.message).foregroundStyle(s.messageIsError ? .orange : .green)
            }
        case 2:
            Text("Let the app hear the meeting").font(.title.bold())
            Text("Pick the apps you have meetings in. The app records only their audio, so YouTube or music elsewhere stays out. Or choose BlackHole to capture any app (needs a one-time audio setup).")
            AudioSourcePicker(s: s, onChange: {
                ConfigFile.update(engine.configURL, [
                    "audio_source": s.audioSource,
                    "capture_apps": CaptureApp.known.map(\.id).filter { s.captureApps.contains($0) },
                ])
                checker.refresh(engine)
            })
            SetupChecklist(checker: checker, engine: engine, only: [.capture, .blackhole, .multiOutput, .output])
            Text("Your own voice isn't captured, only what the meeting plays (other people).")
                .font(.callout).foregroundStyle(.secondary)
        case 3:
            Text("Permissions and tools").font(.title.bold())
            Text("Allow these so the app can listen and alert you.")
            SetupChecklist(checker: checker, engine: engine, only: [.microphone, .notifications, .engine, .claude])
            Text("With meeting-app capture, macOS asks once to allow recording app audio when you first start listening. Click Allow.")
                .font(.callout).foregroundStyle(.secondary)
        default:
            Text("All set?").font(.title.bold())
            SetupChecklist(checker: checker, engine: engine)
            if checker.needSetup.isEmpty {
                Label("Everything required is ready. Press Start listening when your meeting begins.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Some items still need setup. You can finish them later in the Setup tab.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func next() {
        if step == 1 {
            s.save(to: engine)
            if s.listeningFor.isEmpty || (s.messageIsError && !s.message.hasPrefix("Saved")) { return }
            checker.refresh(engine)
        }
        if step == titles.count - 1 { finish(); return }
        step += 1
    }
}

// MARK: - Floating alerts (work during Focus / Do Not Disturb and screen sharing)

struct PopupCard: Identifiable {
    enum Kind { case question, called, mention, audio }
    let id = UUID()
    let kind: Kind
    let time: String
    let title: String
    let body: String
    var answer: String = ""
    var confidence: String = ""
}

/// Sends a regular macOS notification as "Meet for Me" (backup to the floating window).
enum Notifier {
    static let delegate = NotifierDelegate()

    static func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        // Ask now only if the setup guide was already completed; otherwise the guide asks.
        if UserDefaults.standard.bool(forKey: "setupGuideDone") {
            c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(title: String, subtitle: String = "", body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Show banners even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// A small always-on-top window in the top-right corner. Focus modes don't affect it, and it is
/// excluded from screen sharing / recording so other participants never see your drafted answers.
@MainActor
final class PopupCenter: ObservableObject {
    @Published var cards: [PopupCard] = []
    private var panel: NSPanel?
    private var host: NSHostingView<PopupStack>?
    private var lastMention = Date.distantPast

    func show(_ card: PopupCard) {
        if card.kind == .mention {
            // Name heard: short-lived heads-up; replaced by the question card if one follows.
            guard Date().timeIntervalSince(lastMention) > 20 else { return }
            lastMention = Date()
        }
        if card.kind == .question || card.kind == .called {
            cards.removeAll { $0.kind == .mention }
            NSSound(named: "Glass")?.play()
        }
        if card.kind == .audio { cards.removeAll { $0.kind == .audio } }
        cards.insert(card, at: 0)
        if cards.count > 4 { cards.removeLast(cards.count - 4) }
        if card.kind == .mention || card.kind == .audio {
            let id = card.id
            DispatchQueue.main.asyncAfter(deadline: .now() + (card.kind == .mention ? 20 : 30)) {
                self.dismiss(id)
            }
        }
        refresh()
    }

    func dismiss(_ id: UUID) {
        cards.removeAll { $0.id == id }
        refresh()
    }

    func clearAudioWarning() {
        if cards.contains(where: { $0.kind == .audio }) {
            cards.removeAll { $0.kind == .audio }
            refresh()
        }
    }

    private func makePanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none   // hidden from screen sharing and recordings
        let h = NSHostingView(rootView: PopupStack(center: self))
        p.contentView = h
        panel = p
        host = h
    }

    private func refresh() {
        if cards.isEmpty { panel?.orderOut(nil); return }
        if panel == nil { makePanel() }
        guard let panel, let host else { return }
        DispatchQueue.main.async {
            let size = host.fittingSize
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
        }
    }
}

struct PopupStack: View {
    @ObservedObject var center: PopupCenter
    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.cards) { PopupCardView(card: $0, center: center) }
        }
        .padding(8)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PopupCardView: View {
    let card: PopupCard
    let center: PopupCenter

    private var icon: (String, Color) {
        switch card.kind {
        case .question: return ("questionmark.bubble.fill", .orange)
        case .called: return ("person.wave.2.fill", .blue)
        case .mention: return ("ear.fill", .secondary)
        case .audio: return ("speaker.slash.fill", .red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon.0).foregroundStyle(icon.1)
                Text(card.title).font(.headline)
                if !card.confidence.isEmpty {
                    Text(card.confidence).font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer()
                Text(card.time).font(.caption).foregroundStyle(.secondary)
                Button { center.dismiss(card.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
            }
            if !card.body.isEmpty {
                Text(card.body).font(card.kind == .question ? .body.weight(.semibold) : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.answer.isEmpty {
                Text(card.answer).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.answer, forType: .string)
                    } label: { Label("Copy answer", systemImage: "doc.on.doc") }
                    Spacer()
                    Button("Open app") { openMainWindow() }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(icon.1.opacity(0.5), lineWidth: 1))
        .shadow(radius: 6, y: 2)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Meet for Me" }?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Engine (runs listener.py)

@MainActor
final class Engine: ObservableObject {
    @AppStorage("engineFolder") var folderPath: String =
        NSHomeDirectory() + "/Documents/zoom-listener"

    @Published var state: EngineState = .stopped
    @Published var lines: [TranscriptLine] = []
    @Published var alerts: [AlertItem] = []
    @Published var log: [String] = []
    let popup = PopupCenter()
    @Published var captureSources: [String] = []   // bundle IDs currently being captured
    @Published var usingAppCapture = false
    private var capture: AppAudioCapture?
    private let writeQueue = DispatchQueue(label: "meetforme.pipe")
    @Published var audioOK = true            // engine heard something recently
    @Published var silentFor = 0
    @Published var outputDevice: String? = defaultOutputDeviceName()
    private var outputTimer: Timer?

    private var process: Process?
    private var buffer = Data()

    var folder: URL { URL(fileURLWithPath: folderPath) }
    var python: URL { folder.appendingPathComponent(".venv/bin/python") }
    var script: URL { folder.appendingPathComponent("listener.py") }
    var configURL: URL { folder.appendingPathComponent("config.json") }
    var contextURL: URL { folder.appendingPathComponent("context.md") }

    var engineMissing: String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: script.path) { return "listener.py not found in \(folderPath)" }
        if !fm.fileExists(atPath: python.path) { return "Python environment (.venv) not found in \(folderPath)" }
        return nil
    }

    /// GUI apps get a minimal PATH; the engine needs `claude` (and maybe `ollama`).
    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:\(home)/.claude/local:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    func start() {
        guard !state.isRunning else { return }
        if let missing = engineMissing { state = .failed(missing); return }
        state = .starting
        if ConfigFile.audioSource(ConfigFile.read(configURL)) == "apps" {
            launch()  // per-app capture: macOS asks for "system audio recording" on first use
            return
        }
        // BlackHole mode: ask for microphone access up front so macOS attributes it to this app.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                if granted { self.launch() } else {
                    self.state = .failed("Microphone access denied: allow it in System Settings → Privacy → Microphone")
                }
            }
        }
    }

    private func launch() {
        let p = Process()
        p.executableURL = python
        let cfg = ConfigFile.read(configURL)
        let appMode = ConfigFile.audioSource(cfg) == "apps"
        p.arguments = ["-u", script.path, "--events", "--quiet"]  // the app shows alerts itself
            + (appMode ? ["--audio-stdin"] : [])
        let audioPipe = Pipe()
        if appMode { p.standardInput = audioPipe }
        p.currentDirectoryURL = folder
        p.environment = Engine.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.capture?.stop()
                self.capture = nil
                self.captureSources = []
                self.stopOutputWatch()
                if case .failed = self.state { return }
                if proc.terminationStatus != 0 && proc.terminationReason == .exit {
                    let last = self.log.last(where: { !$0.isEmpty }) ?? "exit code \(proc.terminationStatus)"
                    self.state = .failed("Engine stopped: \(last)")
                } else {
                    self.state = .stopped
                }
            }
        }
        do {
            try p.run()
            process = p
            audioOK = true
            usingAppCapture = appMode
            startOutputWatch()
            if appMode {
                let writer = audioPipe.fileHandleForWriting
                let wq = writeQueue
                let cap = AppAudioCapture(
                    prefixes: ConfigFile.captureApps(cfg),
                    onAudio: { data in wq.async { try? writer.write(contentsOf: data) } },
                    onSources: { ids in Task { @MainActor [weak self] in
                        if self?.captureSources != ids { self?.captureSources = ids } } })
                cap.logURL = folder.appendingPathComponent("logs/capture.log")
                cap.onReport = { msg in Task { @MainActor [weak self] in self?.log.append("[capture] " + msg) } }
                cap.start()
                capture = cap
            }
        } catch {
            state = .failed("Could not start engine: \(error.localizedDescription)")
        }
    }

    private func startOutputWatch() {
        outputDevice = defaultOutputDeviceName()
        outputTimer?.invalidate()
        outputTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.outputDevice = defaultOutputDeviceName() }
        }
    }

    private func stopOutputWatch() {
        outputTimer?.invalidate()
        outputTimer = nil
        audioOK = true
    }

    func stop() {
        guard let p = process else { state = .stopped; return }
        p.interrupt()  // SIGINT → clean "Stopped."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(String(decoding: lineData, as: UTF8.self))
        }
    }

    private func handle(_ line: String) {
        guard line.hasPrefix("@@EVENT ") else {
            log.append(line)
            if log.count > 500 { log.removeFirst(log.count - 500) }
            return
        }
        let json = Data(line.dropFirst(8).utf8)
        guard let ev = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let kind = ev["kind"] as? String else { return }
        let time = ev["time"] as? String ?? ""
        switch kind {
        case "status":
            switch ev["state"] as? String {
            case "loading": state = .loading
            case "listening": state = .listening
            case "stopped": state = .stopped
            default: break
            }
        case "transcript":
            let mention = ev["mention"] as? Bool ?? false
            let text = ev["text"] as? String ?? ""
            lines.append(TranscriptLine(time: time, text: text, mention: mention))
            if mention {
                popup.show(PopupCard(kind: .mention, time: time, title: "Your name was mentioned", body: text))
            }
            if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        case "answer":
            let q = ev["question"] as? String ?? ""
            let a = ev["answer"] as? String ?? ""
            let conf = ev["confidence"] as? String ?? ""
            popup.show(PopupCard(kind: .question, time: time, title: "Question for you", body: q,
                                 answer: a, confidence: conf))
            Notifier.post(title: "Question for you", subtitle: q, body: a)
            alerts.insert(AlertItem(time: time,
                                    question: ev["question"] as? String ?? "",
                                    answer: ev["answer"] as? String ?? "",
                                    confidence: ev["confidence"] as? String ?? "",
                                    sources: ev["sources"] as? [String] ?? [],
                                    file: ev["file"] as? String ?? ""), at: 0)
        case "audio":
            audioOK = ev["ok"] as? Bool ?? true
            silentFor = ev["silent_for"] as? Int ?? 0
            if audioOK {
                popup.clearAudioWarning()
            } else {
                let msg = "Nothing heard for \(silentFor)s. Set the meeting's speaker (or Mac Sound → Output) to Multi-Output Device."
                popup.show(PopupCard(kind: .audio, time: time, title: "No meeting audio", body: msg))
                Notifier.post(title: "No meeting audio", body: msg)
            }
        case "called":
            let text = ev["text"] as? String ?? ""
            popup.show(PopupCard(kind: .called, time: time, title: "Someone called you",
                                 body: text + "\nNo question followed yet."))
            Notifier.post(title: "Someone called you", body: text)
        case "error":
            let msg = ev["message"] as? String ?? "Error"
            if ev["trigger"] == nil { state = .failed(msg) } else { log.append("Error: " + msg) }
        default: break
        }
    }

    func clear() { lines.removeAll(); alerts.removeAll() }

    func showTestAlerts() {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        popup.show(PopupCard(kind: .question, time: t, title: "Question for you",
                             body: "Bug hoàn tiền có kịp fix trước buổi demo không ạ?",
                             answer: "Bug hoàn tiền bên anh dự kiến fix xong thứ Ba tuần sau, kịp trước buổi demo thứ Năm nhé em.",
                             confidence: "high"))
        Notifier.post(title: "Question for you", subtitle: "Bug hoàn tiền có kịp fix trước buổi demo không ạ?",
                      body: "Bug hoàn tiền bên anh dự kiến fix xong thứ Ba tuần sau, kịp trước buổi demo thứ Năm nhé em.")
    }

    /// Run listener.py with arguments and stdin, off the main thread (used by the chat).
    nonisolated static func run(python: URL, script: URL, folder: URL, args: [String],
                                input: Data?) async -> (ok: Bool, output: String, error: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = python
                p.arguments = [script.path] + args
                p.currentDirectoryURL = folder
                p.environment = Engine.environment
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch {
                    cont.resume(returning: (false, "", error.localizedDescription)); return
                }
                if let input { inp.fileHandleForWriting.write(input) }
                try? inp.fileHandleForWriting.close()
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus == 0,
                                        String(decoding: o, as: UTF8.self),
                                        String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// Run listener.py with arguments and return its combined output.
    func runTool(_ args: [String]) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path] + args
        p.currentDirectoryURL = folder
        p.environment = Engine.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Settings model (config.json + context.md)

@MainActor
final class SettingsModel: ObservableObject {
    @Published var names = ""
    @Published var aliases = ""
    @Published var jargon = ""
    @Published var device = "BlackHole 2ch"
    @Published var devices: [String] = []
    @Published var audioSource = "apps"
    @Published var captureApps: Set<String> = Set(CaptureApp.defaults)
    @Published var language = "vi"
    @Published var backend = "claude"
    @Published var claudeModel = "sonnet"
    @Published var ollamaModel = "qwen3:8b"
    @Published var notes = ""
    @Published var listeningFor: [String] = []
    @Published var message = ""
    @Published var messageIsError = false

    func load(from engine: Engine) {
        message = ""
        var cfg: [String: Any] = [:]
        if let d = try? Data(contentsOf: engine.configURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cfg = obj }
        let myNames = cfg["my_names"] as? [String] ?? []
        listeningFor = myNames
        names = (cfg["name_input"] as? [String] ?? myNames.filter { $0.unicodeScalars.contains { !$0.isASCII } })
            .joined(separator: ", ")
        aliases = (cfg["alias_input"] as? [String] ?? []).joined(separator: ", ")
        jargon = cfg["jargon"] as? String ?? ""
        if jargon.isEmpty, let p = cfg["whisper_prompt"] as? String,
           let r = p.range(of: "Thuật ngữ: ") {
            jargon = String(p[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        device = cfg["audio_device"] as? String ?? "BlackHole 2ch"
        audioSource = ConfigFile.audioSource(cfg)
        captureApps = Set(ConfigFile.captureApps(cfg))
        language = (cfg["language"] as? String) ?? "auto"
        backend = cfg["llm_backend"] as? String ?? "claude"
        claudeModel = cfg["claude_model"] as? String ?? "sonnet"
        ollamaModel = cfg["ollama_model"] as? String ?? "qwen3:8b"
        notes = (try? String(contentsOf: engine.contextURL, encoding: .utf8)) ?? ""
        refreshDevices(engine)
    }

    func refreshDevices(_ engine: Engine) {
        guard engine.engineMissing == nil else { return }
        let r = engine.runTool(["--list-inputs-json"])
        if r.ok, let d = r.output.split(separator: "\n").last.map({ Data($0.utf8) }),
           let list = try? JSONSerialization.jsonObject(with: d) as? [String] {
            devices = list
        }
        if !devices.contains(device) { devices.insert(device, at: 0) }
    }

    func save(to engine: Engine) {
        if let missing = engine.engineMissing { show(missing, error: true); return }
        guard !names.trimmingCharacters(in: .whitespaces).isEmpty else {
            show("Enter your name first.", error: true); return
        }
        // 1) plain settings straight into config.json
        var cfg: [String: Any] = [:]
        if let d = try? Data(contentsOf: engine.configURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cfg = obj }
        cfg["audio_device"] = device
        cfg["audio_source"] = audioSource
        cfg["capture_apps"] = CaptureApp.known.map(\.id).filter { captureApps.contains($0) }
        cfg["language"] = language == "auto" ? NSNull() : language
        cfg["llm_backend"] = backend
        cfg["claude_model"] = claudeModel
        cfg["ollama_model"] = ollamaModel
        do {
            let d = try JSONSerialization.data(withJSONObject: cfg,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: engine.configURL)
            try notes.write(to: engine.contextURL, atomically: true, encoding: .utf8)
        } catch {
            show("Could not save: \(error.localizedDescription)", error: true); return
        }
        // 2) names go through listener.py so the Vietnamese rules are applied
        let r = engine.runTool(["--set-name", names, "--aliases", aliases, "--jargon", jargon])
        let warnings = r.output.split(separator: "\n").filter { $0.contains("Skipped") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        load(from: engine)
        if !r.ok {
            show(r.output.trimmingCharacters(in: .whitespacesAndNewlines), error: true)
        } else if !warnings.isEmpty {
            show("Saved, with a warning:\n" + warnings.joined(separator: "\n"), error: true)
        } else {
            show(engine.state.isRunning ? "Saved. Stop and start listening to apply." : "Saved.", error: false)
        }
    }

    private func show(_ m: String, error: Bool) { message = m; messageIsError = error }
}

// MARK: - Views

struct StatusBar: View {
    @ObservedObject var engine: Engine
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(engine.state.color).frame(width: 10, height: 10)
            Text(engine.state.label).lineLimit(2).textSelection(.enabled)
            Spacer()
            if engine.state.isRunning {
                Button { engine.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { engine.start() } label: { Label("Start listening", systemImage: "ear") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

struct AudioWarning: View {
    @ObservedObject var engine: Engine
    var body: some View {
        let wrongOutput = !engine.usingAppCapture && !outputReachesBlackHole(engine.outputDevice)
        if engine.state.isRunning && (wrongOutput || !engine.audioOK) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    if !engine.audioOK {
                        Text("No meeting audio for \(engine.silentFor)s").font(.headline)
                    } else {
                        Text("Meeting audio may not reach the listener").font(.headline)
                    }
                    Text(engine.usingAppCapture
                         ? (engine.captureSources.isEmpty
                            ? "None of the selected meeting apps is playing audio yet. Join the meeting, or pick the right app in Settings → Audio source."
                            : "Capturing \(engine.captureSources.joined(separator: ", ")), but it's silent. Is the meeting muted?")
                         : "Mac sound output is \u{201C}\(engine.outputDevice ?? "unknown")\u{201D}. "
                         + "For Zoom in a browser, set it to Multi-Output Device. "
                         + "For the Zoom app, set Zoom → Settings → Audio → Speaker to Multi-Output Device.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Sound Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
        }
    }
}

struct AlertCard: View {
    let item: AlertItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.time).font(.caption).foregroundStyle(.secondary)
                if !item.confidence.isEmpty {
                    Text(item.confidence).font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.answer, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy answer")
            }
            Text(item.question).font(.headline).textSelection(.enabled)
            Text(item.answer).textSelection(.enabled)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    if item.sources.isEmpty {
                        Text("Not covered by the meeting or your notes.")
                    }
                    ForEach(item.sources, id: \.self) { src in
                        Label(src, systemImage: src.lowercased().hasPrefix("notes")
                              ? "note.text" : (src.lowercased().hasPrefix("transcript") ? "text.bubble" : "info.circle"))
                            .textSelection(.enabled)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text(item.sources.isEmpty ? "Based on: nothing found"
                     : "Based on \(item.sources.count) source\(item.sources.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let onAsk: (TranscriptLine) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(line.text).textSelection(.enabled)
                .fontWeight(line.mention ? .semibold : .regular)
            Spacer(minLength: 4)
            Button { onAsk(line) } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderless)
            .help("Ask about this line in Chat")
            .opacity(hovering ? 1 : 0)       // only visible on hover
            .allowsHitTesting(hovering)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct LiveView: View {
    @ObservedObject var engine: Engine
    var onAsk: (TranscriptLine) -> Void = { _ in }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Questions for you").font(.headline).padding([.horizontal, .top], 12)
                if engine.alerts.isEmpty {
                    Spacer()
                    Text("Nothing yet. Questions addressed to you show up here with a drafted answer.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(engine.alerts) { AlertCard(item: $0) }
                        }.padding(12)
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 360)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    Button("Clear") { engine.clear() }.buttonStyle(.borderless)
                    Button("Open folder") {
                        NSWorkspace.shared.open(engine.folder.appendingPathComponent("transcripts"))
                    }.buttonStyle(.borderless)
                }.padding([.horizontal, .top], 12)
                ScrollViewReader { proxy in
                    List(engine.lines) { l in
                        TranscriptRow(line: l, onAsk: onAsk)
                        .listRowBackground(l.mention ? Color.yellow.opacity(0.18) : Color.clear)
                        .id(l.id)
                    }
                    .onChange(of: engine.lines.count) {
                        if let last = engine.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(minWidth: 320)
        }
    }
}

/// Choose per-app capture (with app toggles) or the BlackHole device.
struct AudioSourcePicker: View {
    @ObservedObject var s: SettingsModel
    var onChange: (() -> Void)? = nil
    @State private var playing: Set<String> = []
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Listen to", selection: $s.audioSource) {
                Text("Meeting apps directly (recommended)").tag("apps")
                Text("BlackHole device (any app, needs audio setup)").tag("blackhole")
            }
            .onChange(of: s.audioSource) { onChange?() }
            if s.audioSource == "apps" {
                Text("Only these apps are recorded, so YouTube or music in other apps stays out. No BlackHole needed. A browser is captured as a whole, so play YouTube in a different browser than your meeting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(CaptureApp.known) { app in
                    Toggle(isOn: Binding(
                        get: { s.captureApps.contains(app.id) },
                        set: { on in
                            if on { s.captureApps.insert(app.id) } else { s.captureApps.remove(app.id) }
                            onChange?()
                        })) {
                        HStack {
                            Text(app.name)
                            if playing.contains(app.id) {
                                Text("playing now").font(.caption2.bold()).foregroundStyle(.green)
                            }
                        }
                    }
                }
            } else {
                Picker("Audio input", selection: $s.device) {
                    ForEach(s.devices, id: \.self) { Text($0).tag($0) }
                }
                Text("Needs BlackHole and a Multi-Output Device: see the Setup tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        let live = AudioProcesses.all().filter(\.playing).map { $0.bundleID.lowercased() }
        playing = Set(CaptureApp.known.map(\.id).filter { id in live.contains { $0.hasPrefix(id.lowercased()) } })
    }
}

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @StateObject private var s = SettingsModel()

    var body: some View {
        Form {
            Section("Your name") {
                TextField("Name(s), with tone marks", text: $s.names, prompt: Text("Hiếu, Trung Hiếu"))
                TextField("Other names", text: $s.aliases, prompt: Text("Hugh, Henry (optional)"))
                if !s.listeningFor.isEmpty {
                    Text("Listening for: " + s.listeningFor.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Use the full given name if it is also a pronoun (Đức Anh, not Anh). Versions without tone marks are added automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio source") {
                AudioSourcePicker(s: s)
            }
            Section("Transcription") {
                Picker("Language", selection: $s.language) {
                    Text("Vietnamese").tag("vi")
                    Text("English").tag("en")
                    Text("Auto-detect").tag("auto")
                }
                TextField("Project words", text: $s.jargon, prompt: Text("API, deploy, staging (optional)"))
            }
            Section("Answers") {
                Picker("Engine", selection: $s.backend) {
                    Text("Claude Code (your plan)").tag("claude")
                    Text("Ollama (offline)").tag("ollama")
                }
                if s.backend == "claude" {
                    Picker("Claude model", selection: $s.claudeModel) {
                        Text("Haiku: fastest").tag("haiku")
                        Text("Sonnet: balanced").tag("sonnet")
                        Text("Opus: best").tag("opus")
                    }
                } else {
                    TextField("Ollama model", text: $s.ollamaModel)
                }
                VStack(alignment: .leading) {
                    Text("Optional notes: answers come from the meeting first, then these (your role, project status, deadlines)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $s.notes)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                }
            }
            Section("Engine") {
                HStack {
                    Text(engine.folderPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseFolder() }
                }
                Button("Send a test notification") { _ = engine.runTool(["--test-notify"]) }
            }
            HStack {
                if !s.message.isEmpty {
                    Text(s.message).font(.callout)
                        .foregroundStyle(s.messageIsError ? .red : .green)
                }
                Spacer()
                Button("Revert") { s.load(from: engine) }
                Button("Save") { s.save(to: engine) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
        .onAppear { s.load(from: engine) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = engine.folder
        panel.message = "Choose the folder that contains listener.py"
        if panel.runModal() == .OK, let url = panel.url {
            engine.folderPath = url.path
            s.load(from: engine)
        }
    }
}

// MARK: - Chat about the meeting

struct ChatMessage: Identifiable {
    enum Role: String { case user, assistant, error }
    let id = UUID()
    let role: Role
    let text: String          // shown in the bubble
    var sent: String? = nil   // what was actually asked, if different
}

struct MeetingOption: Hashable {
    let value: String   // "today" or a transcript file name
    let label: String
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var busy = false
    @Published var meetings: [MeetingOption] = [MeetingOption(value: "today", label: "Today (all)")]
    @Published var meeting = "today"

    func refreshMeetings(_ engine: Engine) {
        let dir = engine.folder.appendingPathComponent("transcripts")
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "txt" }
            .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var opts = [MeetingOption(value: "today", label: "Today (all)")]
        for f in files.prefix(40) {
            // 2026-11-13_1446.txt -> "13/11 14:46"
            let n = f.deletingPathExtension().lastPathComponent
            let parts = n.split(separator: "_")
            var label = n
            if parts.count == 2, parts[1].count == 4 {
                let d = parts[0].split(separator: "-")
                let t = parts[1]
                if d.count == 3 { label = "\(d[2])/\(d[1]) \(t.prefix(2)):\(t.suffix(2))" }
            }
            opts.append(MeetingOption(value: f.lastPathComponent, label: label))
        }
        meetings = opts
        if !opts.contains(where: { $0.value == meeting }) { meeting = "today" }
    }

    /// Ask the chat about one transcript line (from the Live tab's hover button).
    func askAbout(_ line: TranscriptLine, _ engine: Engine) {
        meeting = "today"  // the live session is part of today's transcripts
        let q = "Câu này trong cuộc họp lúc \(line.time): \u{201C}\(line.text)\u{201D}. "
            + "Nếu đây là câu hỏi, hãy trả lời dựa trên cuộc họp (và ghi chú nếu có); "
            + "nếu không, giải thích ý và bối cảnh của nó trong cuộc họp."
        send(engine, text: q, display: "\u{201C}\(line.text)\u{201D}  (\(line.time))")
    }

    func send(_ engine: Engine, text: String? = nil, display: String? = nil) {
        let q = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        if let missing = engine.engineMissing {
            messages.append(ChatMessage(role: .error, text: missing)); return
        }
        let history = messages.filter { $0.role != .error }
            .map { ["role": $0.role.rawValue, "text": $0.sent ?? $0.text] }
        messages.append(ChatMessage(role: .user, text: display ?? q, sent: display == nil ? nil : q))
        input = ""
        busy = true
        let payload: [String: Any] = ["question": q, "history": history, "meeting": meeting]
        let data = try? JSONSerialization.data(withJSONObject: payload)
        let (py, sc, fo) = (engine.python, engine.script, engine.folder)
        Task {
            let r = await Engine.run(python: py, script: sc, folder: fo,
                                     args: ["--ask-stdin"], input: data)
            busy = false
            let answer = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, !answer.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: answer))
            } else {
                let err = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(ChatMessage(role: .error,
                                            text: err.isEmpty ? "No answer." : String(err.suffix(400))))
            }
        }
    }
}

struct ChatBubble: View {
    let msg: ChatMessage
    var body: some View {
        HStack {
            if msg.role == .user { Spacer(minLength: 60) }
            Text(msg.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(
                    msg.role == .user ? Color.accentColor.opacity(0.85)
                    : msg.role == .error ? Color.red.opacity(0.15)
                    : Color.secondary.opacity(0.12)))
                .foregroundStyle(msg.role == .user ? Color.white : Color.primary)
            if msg.role != .user { Spacer(minLength: 60) }
        }
    }
}

struct ChatView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var chat: ChatModel
    private let suggestions = [
        "Tóm tắt cuộc họp",
        "Có ai hỏi mình gì không?",
        "Mình được giao việc gì?",
        "Có quyết định hay deadline nào?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Meeting", selection: $chat.meeting) {
                    ForEach(chat.meetings, id: \.self) { Text($0.label).tag($0.value) }
                }
                .frame(maxWidth: 260)
                Button { chat.refreshMeetings(engine) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh meeting list")
                Spacer()
                Button("Clear chat") { chat.messages.removeAll() }
                    .buttonStyle(.borderless).disabled(chat.messages.isEmpty)
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Ask anything about the meeting").font(.headline)
                                Text("Answers come from the transcript (and your notes), with times like (14:37).")
                                    .font(.callout).foregroundStyle(.secondary)
                                FlowRow(items: suggestions) { s in chat.send(engine, text: s) }
                            }
                            .padding(.top, 8)
                        }
                        ForEach(chat.messages) { ChatBubble(msg: $0).id($0.id) }
                        if chat.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Reading the transcript…").foregroundStyle(.secondary)
                            }
                            .id("busy")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chat.messages.count) {
                    withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: chat.busy) {
                    if chat.busy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about the meeting…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { chat.send(engine) }
                Button { chat.send(engine) } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(chat.busy || chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .onAppear { chat.refreshMeetings(engine) }
    }
}

/// Simple wrapping row of suggestion buttons.
struct FlowRow: View {
    let items: [String]
    let action: (String) -> Void
    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { action(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: Engine
    @StateObject private var chat = ChatModel()
    @StateObject private var checker = SetupChecker()
    @AppStorage("setupGuideDone") private var setupGuideDone = false
    @State private var showGuide = false
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            StatusBar(engine: engine)
            AudioWarning(engine: engine)
            if !checker.needSetup.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                    Text("\(checker.needSetup.count) setup item(s) need attention: "
                         + checker.needSetup.map(\.title).joined(separator: ", "))
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Button("Show") { tab = 3 }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
            }
            Divider()
            TabView(selection: $tab) {
                LiveView(engine: engine, onAsk: { line in
                    tab = 2
                    chat.askAbout(line, engine)
                }).tabItem { Text("Live") }.tag(0)
                ChatView(engine: engine, chat: chat).tabItem { Text("Chat") }.tag(2)
                SetupTab(engine: engine, checker: checker, openGuide: { showGuide = true })
                    .tabItem { Text(checker.needSetup.isEmpty ? "Setup" : "Setup ⚠︎") }.tag(3)
                SettingsView(engine: engine).tabItem { Text("Settings") }.tag(1)
            }
            .padding(.top, 6)
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: $showGuide) {
            OnboardingView(engine: engine, checker: checker) {
                setupGuideDone = true
                showGuide = false
                checker.refresh(engine)
            }
        }
        .onAppear {
            checker.refresh(engine)  // a setup pass on every launch
            if !setupGuideDone || CommandLine.arguments.contains("--setup-guide") { showGuide = true }
            if CommandLine.arguments.contains("--autostart") { engine.start() }
        }
        .onChange(of: engine.state) { checker.refresh(engine) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: Engine?
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)  // the engine may exit while capture audio is being written
        Notifier.setUp()
        if CommandLine.arguments.contains("--test-popup") {  // dev: show sample alerts
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self.engine?.showTestAlerts() }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { engine?.stop() }
    }
}

@main
struct MeetForMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Meet for Me", id: "main") {
            ContentView(engine: engine)
                .onAppear { delegate.engine = engine }
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            Text(engine.state.label)
            Divider()
            if engine.state.isRunning {
                Button("Stop listening") { engine.stop() }
            } else {
                Button("Start listening") { engine.start() }
            }
            Button("Open window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") { engine.stop(); NSApp.terminate(nil) }
        } label: {
            Image(systemName: engine.state.isRunning ? "ear.fill" : "ear")
        }
    }
}
