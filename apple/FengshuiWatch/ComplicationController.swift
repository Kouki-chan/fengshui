import ClockKit

/// Minimal ClockKit complication inside the watch app (DECISIONS D-07): having it on
/// the active face raises the app's background-refresh budget. Filled in Phase 3.
final class ComplicationController: NSObject, CLKComplicationDataSource {
    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        handler([CLKComplicationDescriptor(identifier: "status", displayName: "Fengshui",
                                           supportedFamilies: [.graphicCorner, .graphicCircular, .modularSmall])])
    }

    func getCurrentTimelineEntry(for complication: CLKComplication,
                                 withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        handler(nil)
    }
}
