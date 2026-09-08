import Defaults
import SwiftUI

private struct GuideEntry: Identifiable {
    let id = UUID()
    let icon: String
    let titleEN: String
    let titleVI: String
    let bodyEN: String
    let bodyVI: String
}

private let guideEntries: [GuideEntry] = [
    GuideEntry(
        icon: "music.note",
        titleEN: "Music Player",
        titleVI: "Trình phát nhạc",
        bodyEN: "Hover the notch to expand it and control playback for Apple Music, Spotify, YouTube Music, or the system Now Playing. Customize which buttons show, and their order, in Settings > Media.",
        bodyVI: "Rê chuột vào notch để mở rộng và điều khiển phát nhạc từ Apple Music, Spotify, YouTube Music, hoặc Now Playing của hệ thống. Tùy chỉnh nút nào hiện và thứ tự của chúng trong Settings > Media."
    ),
    GuideEntry(
        icon: "slider.horizontal.3",
        titleEN: "System HUD Replacement",
        titleVI: "Thay thế HUD hệ thống",
        bodyEN: "Once Accessibility access is granted, volume, brightness, and keyboard backlight keys show a custom HUD on the notch instead of macOS's own. Toggle in Settings > HUD.",
        bodyVI: "Sau khi cấp quyền Accessibility, các phím âm lượng, độ sáng màn hình và đèn bàn phím sẽ hiện HUD tùy chỉnh trên notch thay vì HUD mặc định của macOS. Bật/tắt ở Settings > HUD."
    ),
    GuideEntry(
        icon: "books.vertical",
        titleEN: "Shelf",
        titleVI: "Kệ tạm (Shelf)",
        bodyEN: "Drag files onto the notch to hold them temporarily. From there, Quick Look, AirDrop/share, remove image backgrounds, convert image formats, or merge several images into a PDF. Turn on in Settings > Modules.",
        bodyVI: "Kéo file vào notch để giữ tạm. Từ đó có thể QuickLook xem trước, AirDrop/chia sẻ, xoá nền ảnh, đổi định dạng ảnh, hoặc gộp nhiều ảnh thành PDF. Bật ở Settings > Modules."
    ),
    GuideEntry(
        icon: "clipboard",
        titleEN: "Clipboard History",
        titleVI: "Lịch sử Khay nhớ tạm",
        bodyEN: "Keeps a history of everything you copy, including images, with quick re-copy. Also automatically picks up anything pasted via Universal Clipboard from your iPhone/iPad. Turn on in Settings > Modules.",
        bodyVI: "Lưu lại lịch sử mọi thứ bạn sao chép, kể cả ảnh, và cho sao chép lại nhanh. Cũng tự động bắt được nội dung dán qua Universal Clipboard từ iPhone/iPad. Bật ở Settings > Modules."
    ),
    GuideEntry(
        icon: "calendar",
        titleEN: "Calendar",
        titleVI: "Lịch",
        bodyEN: "Shows your upcoming calendar events and reminders right on the notch. Turn on in Settings > Modules, then grant Calendar/Reminders access when prompted.",
        bodyVI: "Hiện sự kiện lịch và nhắc nhở sắp tới ngay trên notch. Bật ở Settings > Modules, rồi cấp quyền Calendar/Reminders khi được hỏi."
    ),
    GuideEntry(
        icon: "web.camera",
        titleEN: "Camera Mirror",
        titleVI: "Gương Camera",
        bodyEN: "A quick self-view from your Mac's camera, right on the notch — handy for checking yourself before a call. Turn on in Settings > Modules.",
        bodyVI: "Xem nhanh camera Mac ngay trên notch — tiện để soi gương trước khi vào cuộc gọi. Bật ở Settings > Modules."
    ),
    GuideEntry(
        icon: "airpodspro",
        titleEN: "Bluetooth Device Notifications",
        titleVI: "Thông báo thiết bị Bluetooth",
        bodyEN: "Shows a notch alert (with battery level, when available) when a Bluetooth audio device connects. Configure in Settings > Bluetooth.",
        bodyVI: "Hiện thông báo trên notch (kèm % pin nếu có) khi một thiết bị âm thanh Bluetooth kết nối. Cấu hình ở Settings > Bluetooth."
    ),
    GuideEntry(
        icon: "bolt.horizontal.circle",
        titleEN: "Third-Party Live Activities",
        titleVI: "Live Activity từ ứng dụng khác",
        bodyEN: "Any local app or script can push a status update onto the notch by posting a distributed notification named \"com.cuonghm89.cnotch.liveActivity\" with a JSON payload (title, subtitle, icon, optional progress). Toggle in Settings > Advanced.",
        bodyVI: "Bất kỳ app/script nào trên máy có thể đẩy thông báo trạng thái lên notch bằng cách gửi distributed notification tên \"com.cuonghm89.cnotch.liveActivity\" kèm payload JSON (title, subtitle, icon, tiến trình tuỳ chọn). Bật/tắt ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "mic.slash",
        titleEN: "Mic Mute Toggle",
        titleVI: "Bật/tắt Mic",
        bodyEN: "Press Fn+F5 (customizable in Settings > Shortcuts) to mute/unmute your microphone system-wide, with a HUD confirmation on the notch. Stays in sync if you mute from Control Center instead.",
        bodyVI: "Bấm Fn+F5 (đổi được ở Settings > Shortcuts) để tắt/bật mic toàn hệ thống, có HUD xác nhận trên notch. Vẫn đồng bộ nếu bạn tắt mic từ Control Center."
    ),
    GuideEntry(
        icon: "cloud.sun",
        titleEN: "Weather",
        titleVI: "Thời tiết",
        bodyEN: "Shows the current temperature and condition in the open notch header, using your location (Open-Meteo, no account needed). Turn on in Settings > Advanced.",
        bodyVI: "Hiện nhiệt độ và tình trạng thời tiết hiện tại ở header khi mở rộng notch, dùng vị trí của bạn (Open-Meteo, không cần tài khoản). Bật ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "square.and.pencil",
        titleEN: "Quick Note",
        titleVI: "Ghi chú nhanh",
        bodyEN: "Click the note icon in the open notch header to jot a quick note and save it straight into Notes.app. Turn on in Settings > Advanced.",
        bodyVI: "Bấm icon bút chì ở header khi mở rộng notch để gõ nhanh một ghi chú và lưu thẳng vào Notes.app. Bật ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "camera.viewfinder",
        titleEN: "Screenshot Quick Actions",
        titleVI: "Thao tác nhanh sau khi chụp màn hình",
        bodyEN: "Right after you take a screenshot (Cmd+Shift+3/4), the notch offers Copy, Reveal in Finder, and Delete for a few seconds. Turn on in Settings > Advanced.",
        bodyVI: "Ngay sau khi chụp màn hình (Cmd+Shift+3/4), notch sẽ hiện nút Copy, Xem trong Finder và Xoá trong vài giây. Bật ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "timer",
        titleEN: "Pomodoro Timer",
        titleVI: "Đồng hồ Pomodoro",
        bodyEN: "Click the timer icon in the open notch header and pick 5/15/25 minutes. A countdown with progress ring stays on the closed notch until it finishes (with a notification) or you cancel it. Turn on in Settings > Advanced.",
        bodyVI: "Bấm icon đồng hồ ở header khi mở rộng notch và chọn 5/15/25 phút. Đồng hồ đếm ngược kèm vòng tiến trình hiện trên notch thu gọn tới khi xong (có thông báo) hoặc bạn huỷ. Bật ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "mic",
        titleEN: "Voice Memo",
        titleVI: "Ghi âm nhanh",
        bodyEN: "Click the mic icon in the open notch header to start recording; the notch shows a red dot and elapsed time while recording. Stop to save the recording straight into the Shelf. Turn on in Settings > Advanced.",
        bodyVI: "Bấm icon mic ở header khi mở rộng notch để bắt đầu ghi âm; notch hiện chấm đỏ và thời gian đã ghi. Dừng lại để lưu file ghi âm thẳng vào Kệ tạm. Bật ở Settings > Advanced."
    ),
    GuideEntry(
        icon: "cpu",
        titleEN: "System Stats",
        titleVI: "Thông số hệ thống",
        bodyEN: "Shows current CPU and memory usage as a chip in the open notch header. Turn on in Settings > Advanced.",
        bodyVI: "Hiện % CPU và RAM đang dùng dưới dạng chip ở header khi mở rộng notch. Bật ở Settings > Advanced."
    ),
]

struct HelpGuideView: View {
    @Default(.appLanguage) private var appLanguage

    private var isVietnamese: Bool {
        switch appLanguage {
        case .vi: return true
        case .en: return false
        case .system: return Locale.current.language.languageCode?.identifier == "vi"
        }
    }

    var body: some View {
        Form {
            Section {
                Text(isVietnamese
                     ? "Hướng dẫn nhanh cho từng tính năng của CNotch. Nội dung tự đổi theo ngôn ngữ bạn chọn ở Settings > General."
                     : "A quick guide to every CNotch feature. This content follows the language you pick in Settings > General.")
                    .foregroundStyle(.secondary)
            }

            ForEach(guideEntries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(isVietnamese ? entry.titleVI : entry.titleEN, systemImage: entry.icon)
                            .font(.headline)
                        Text(isVietnamese ? entry.bodyVI : entry.bodyEN)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .accentColor(.effectiveAccent)
    }
}
