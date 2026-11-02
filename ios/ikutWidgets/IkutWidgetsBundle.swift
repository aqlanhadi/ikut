import SwiftUI
import WidgetKit

/// The extension's entry. A widget bundle cannot choose between two widgets by OS version, so two bundles hold the same
/// activity, the later one also offered to the `.small` family (CarPlay, Apple Watch, iOS 18), and the entry picks one.
@main
struct IkutWidgets {
    static func main() {
        if #available(iOS 18.0, *) {
            IkutWidgetsBundleWithSmall.main()
        } else {
            IkutWidgetsBundle.main()
        }
    }
}

struct IkutWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ConvoyLiveActivity()
    }
}

@available(iOS 18.0, *)
struct IkutWidgetsBundleWithSmall: WidgetBundle {
    var body: some Widget {
        ConvoyLiveActivityWithSmall()
    }
}
