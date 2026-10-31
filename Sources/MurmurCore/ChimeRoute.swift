/// Whether the start and stop sounds may play on the Mac's current output. Any sound the Mac
/// plays lets automatic switching pull AirPods away from the iPhone playing on them, so the
/// sounds play only in headphones the Mac already has: a Bluetooth headset connected to it, or
/// wired headphones (the headphone jack, USB). On speakers they stay silent and the HUD alone shows
/// recording.
public enum ChimeRoute {
    /// CoreAudio transport type of the default output and, for a built-in device, its data source.
    public static func allowed(transport: UInt32, dataSource: UInt32?) -> Bool {
        switch transport {
        case MicChoice.fourCC("blue"), MicChoice.fourCC("blea"), MicChoice.fourCC("usb "): true
        case MicChoice.fourCC("bltn"): dataSource == MicChoice.fourCC("hdpn")
        default: false
        }
    }
}
