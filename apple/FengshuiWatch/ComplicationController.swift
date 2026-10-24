import ClockKit
import Foundation

/// Minimal ClockKit complication inside the watch app (DECISIONS D-07). Having it on the
/// active watch face raises the app's background-refresh budget (spec §7.1).
final class ComplicationController: NSObject, CLKComplicationDataSource {
    static func reload() {
        let server = CLKComplicationServer.sharedInstance()
        for c in server.activeComplications ?? [] { server.reloadTimeline(for: c) }
    }

    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        handler([CLKComplicationDescriptor(identifier: "status", displayName: "Fengshui",
                                           supportedFamilies: [.graphicCorner, .graphicCircular, .modularSmall,
                                                               .utilitarianSmall, .circularSmall])])
    }

    func getCurrentTimelineEntry(for complication: CLKComplication,
                                 withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        let pending = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox"),
            includingPropertiesForKeys: nil).count) ?? 0
        let text = CLKSimpleTextProvider(text: pending == 0 ? "FS ✓" : "FS \(pending)")
        let template: CLKComplicationTemplate
        switch complication.family {
        case .graphicCorner: template = CLKComplicationTemplateGraphicCornerTextImage(
            textProvider: text, imageProvider: CLKFullColorImageProvider(fullColorImage: UIImage(systemName: "waveform.path")!))
        case .graphicCircular: template = CLKComplicationTemplateGraphicCircularStackText(
            line1TextProvider: CLKSimpleTextProvider(text: "FS"), line2TextProvider: CLKSimpleTextProvider(text: pending == 0 ? "✓" : "\(pending)"))
        case .modularSmall: template = CLKComplicationTemplateModularSmallSimpleText(textProvider: text)
        case .utilitarianSmall: template = CLKComplicationTemplateUtilitarianSmallFlat(textProvider: text)
        default: template = CLKComplicationTemplateCircularSmallSimpleText(textProvider: text)
        }
        handler(CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template))
    }
}
