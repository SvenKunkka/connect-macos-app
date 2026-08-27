import SwiftUI
import AppKit
import CoreGraphics
import IOKit.hid
import Combine

@main
struct ConnectApp: App {
    @StateObject private var monitor = MouseMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(monitor)
                .frame(width: 340)
        } label: {
            StatusBarLabelView()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MouseActivityState {
    case active
    case idle

    var color: Color {
        switch self {
        case .active:
            return .green
        case .idle:
            return .gray
        }
    }

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .idle:
            return "Idle"
        }
    }
}

struct MouseDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let vendorID: Int?
    let productID: Int?
    let transport: String?
    var inputRatePerSecond: Int
    var activityState: MouseActivityState
}

final class MouseMonitor: ObservableObject {
    @Published private(set) var connectedMice: [MouseDevice] = []
    @Published private(set) var visibleMouse: MouseDevice?

    private let refreshInterval = 0.5
    private let selectedMouseDefaultsKey = "selectedMouseID"

    private var hidManager: IOHIDManager?
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventMonitors: [Any] = []

    private var selectedMouseID: String?
    private var hidValueCountByDeviceID: [String: Int] = [:]
    private var hidReportCountByDeviceID: [String: Int] = [:]
    private var tapMouseEventCount = 0
    private var monitorMouseEventCount = 0
    private var knownMice: [String: MouseDevice] = [:]
    private var deviceMap: [IOHIDDevice: String] = [:]
    private var reportBufferByDeviceID: [String: UnsafeMutablePointer<UInt8>] = [:]

    init() {
        selectedMouseID = UserDefaults.standard.string(forKey: selectedMouseDefaultsKey)
        start()
    }

    deinit {
        stop()
    }

    func selectMouse(_ mouse: MouseDevice) {
        selectedMouseID = mouse.id
        UserDefaults.standard.set(mouse.id, forKey: selectedMouseDefaultsKey)
        publish()
    }

    func isSelected(_ mouse: MouseDevice) -> Bool {
        selectedMouseID == resolvedSelectedMouseID(fallbackToFirst: true, from: connectedMice) && mouse.id == resolvedSelectedMouseID(fallbackToFirst: true, from: connectedMice)
    }

    private func start() {
        setupHIDManager()
        setupMouseEventTap()
        setupMouseEventMonitors()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil

        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()

        for device in deviceMap.keys {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        deviceMap.removeAll()

        for buffer in reportBufferByDeviceID.values {
            buffer.deallocate()
        }
        reportBufferByDeviceID.removeAll()

        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
    }

    private func setupHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager

        let matching = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ] as CFDictionary

        IOHIDManagerSetDeviceMatching(manager, matching)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, _ in
            guard let context, let sender else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleInputValue(sender: sender)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        if let existingDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in existingDevices {
                handleDeviceConnected(device)
            }
        }
    }

    private func setupMouseEventTap() {
        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel
        ]

        let mask = eventTypes.reduce(CGEventMask(0)) { partialResult, type in
            partialResult | (CGEventMask(1) << type.rawValue)
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<MouseMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handleMouseEvent(type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return
        }

        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setupMouseEventMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel
        ]

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.monitorMouseEventCount += 1
        }) {
            eventMonitors.append(globalMonitor)
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.monitorMouseEventCount += 1
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        guard deviceMap[device] == nil else { return }

        let id = makeDeviceID(device)
        deviceMap[device] = id
        hidValueCountByDeviceID[id] = 0
        hidReportCountByDeviceID[id] = 0

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        registerInputReportCallback(for: device, id: id)

        knownMice[id] = MouseDevice(
            id: id,
            name: getStringProperty(device, key: kIOHIDProductKey as CFString) ?? "Mouse",
            vendorID: getIntProperty(device, key: kIOHIDVendorIDKey as CFString),
            productID: getIntProperty(device, key: kIOHIDProductIDKey as CFString),
            transport: getStringProperty(device, key: kIOHIDTransportKey as CFString),
            inputRatePerSecond: 0,
            activityState: .idle
        )

        publish()
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let id = deviceMap.removeValue(forKey: device) else { return }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        knownMice.removeValue(forKey: id)
        hidValueCountByDeviceID.removeValue(forKey: id)
        hidReportCountByDeviceID.removeValue(forKey: id)
        if let buffer = reportBufferByDeviceID.removeValue(forKey: id) {
            buffer.deallocate()
        }

        if selectedMouseID == id {
            selectedMouseID = nil
            UserDefaults.standard.removeObject(forKey: selectedMouseDefaultsKey)
        }

        publish()
    }

    private func handleMouseEvent(type: CGEventType) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .scrollWheel:
            tapMouseEventCount += 1
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        default:
            break
        }
    }

    private func handleInputValue(sender: UnsafeMutableRawPointer) {
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        guard let id = deviceMap[device] else { return }
        hidValueCountByDeviceID[id, default: 0] += 1
    }

    private func registerInputReportCallback(for device: IOHIDDevice, id: String) {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let bufferLength = max(getIntProperty(device, key: kIOHIDMaxInputReportSizeKey as CFString) ?? 64, 64)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        reportBufferByDeviceID[id] = buffer

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferLength,
            { context, result, sender, _, _, report, reportLength in
                guard
                    let context,
                    result == kIOReturnSuccess,
                    let sender,
                    reportLength > 0
                else {
                    return
                }

                let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handleInputReport(sender: sender)
            },
            context
        )
    }

    private func handleInputReport(sender: UnsafeMutableRawPointer) {
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        guard let id = deviceMap[device] else { return }
        hidReportCountByDeviceID[id, default: 0] += 1
    }

    private func tick() {
        let fallbackEventRate = Int(Double(max(tapMouseEventCount, monitorMouseEventCount)) / refreshInterval)
        tapMouseEventCount = 0
        monitorMouseEventCount = 0

        let selectedID = resolvedSelectedMouseID(fallbackToFirst: true, from: connectedMice)

        for id in knownMice.keys {
            guard var mouse = knownMice[id] else { continue }
            let isSelected = id == selectedID
            let hidRate = Int(Double(hidValueCountByDeviceID[id, default: 0]) / refreshInterval)
            let reportRate = Int(Double(hidReportCountByDeviceID[id, default: 0]) / refreshInterval)
            let rate = max(reportRate, hidRate, fallbackEventRate)
            mouse.inputRatePerSecond = isSelected ? rate : 0
            mouse.activityState = isSelected && rate > 0 ? .active : .idle
            knownMice[id] = mouse
            hidValueCountByDeviceID[id] = 0
            hidReportCountByDeviceID[id] = 0
        }

        publish()
    }

    private func publish() {
        let mice = knownMice.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let resolvedID = resolvedSelectedMouseID(fallbackToFirst: true, from: mice)
        let visibleMouse = mice.first { $0.id == resolvedID }

        if selectedMouseID != resolvedID {
            selectedMouseID = resolvedID
            if let resolvedID {
                UserDefaults.standard.set(resolvedID, forKey: selectedMouseDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedMouseDefaultsKey)
            }
        }

        DispatchQueue.main.async {
            self.connectedMice = mice
            self.visibleMouse = visibleMouse
        }
    }

    private func resolvedSelectedMouseID(fallbackToFirst: Bool, from mice: [MouseDevice]) -> String? {
        if let selectedMouseID, mice.contains(where: { $0.id == selectedMouseID }) {
            return selectedMouseID
        }

        return fallbackToFirst ? mice.first?.id : nil
    }

    private func makeDeviceID(_ device: IOHIDDevice) -> String {
        let vendorID = getIntProperty(device, key: kIOHIDVendorIDKey as CFString) ?? 0
        let productID = getIntProperty(device, key: kIOHIDProductIDKey as CFString) ?? 0
        let locationID = getIntProperty(device, key: kIOHIDLocationIDKey as CFString) ?? 0
        return "mouse-\(vendorID)-\(productID)-\(locationID)"
    }

    private func getStringProperty(_ device: IOHIDDevice, key: CFString) -> String? {
        IOHIDDeviceGetProperty(device, key) as? String
    }

    private func getIntProperty(_ device: IOHIDDevice, key: CFString) -> Int? {
        (IOHIDDeviceGetProperty(device, key) as? NSNumber)?.intValue
    }
}

struct StatusBarLabelView: View {
    @EnvironmentObject var monitor: MouseMonitor

    var body: some View {
        if let mouse = monitor.visibleMouse {
            Text("M:\(mouse.inputRatePerSecond)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        } else {
            Label("No Mouse", systemImage: "computermouse")
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject var monitor: MouseMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mouse Input Monitor")
                    .font(.headline)
                Spacer()
                Text("0.5s refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if monitor.connectedMice.isEmpty {
                ContentUnavailableView(
                    "No supported mouse",
                    systemImage: "computermouse",
                    description: Text("Connect a mouse to monitor its input rate.")
                )
                .frame(height: 160)
            } else {
                MouseSelectionSectionView()

                Divider()

                if let mouse = monitor.visibleMouse {
                    MouseRowView(mouse: mouse)
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
    }
}

struct MouseSelectionSectionView: View {
    @EnvironmentObject var monitor: MouseMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visible Mouse")
                .font(.subheadline.weight(.semibold))

            ForEach(monitor.connectedMice) { mouse in
                Button {
                    monitor.selectMouse(mouse)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: monitor.isSelected(mouse) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(monitor.isSelected(mouse) ? .blue : .secondary)
                        Image(systemName: "computermouse")
                            .foregroundStyle(monitor.isSelected(mouse) ? .green : .secondary)
                        Text(mouse.name)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MouseRowView: View {
    let mouse: MouseDevice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "computermouse")
                    .font(.system(size: 24))
                    .frame(width: 32, height: 32)

                Circle()
                    .fill(mouse.activityState.color)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.background, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mouse")
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Text(mouse.activityState.title)
                        .font(.caption)
                        .foregroundStyle(mouse.activityState.color)
                }

                Text(mouse.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Label("\(mouse.inputRatePerSecond) events/s", systemImage: "speedometer")

                    if let transport = mouse.transport {
                        Label(transport, systemImage: "cable.connector")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let vendorID = mouse.vendorID, let productID = mouse.productID {
                    Text("VID: \(vendorID)  PID: \(productID)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}
