import SwiftUI

struct SettingsSubscriptionsSection: View {
    @ObservedObject var interaction: SettingsSubscriptionsInteraction
    private let store = ConfigStore.shared

    // MARK: - 订阅与费用

    var body: some View {
        Card {
            SubscriptionPlansEditor(plans: $interaction.subscriptionPlans)
        }
        .onChange(of: interaction.subscriptionPlans) { _, plans in
            store.subscriptionPlans = plans
        }
    }


}
