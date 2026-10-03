import XCTest
@testable import TokenMeter

final class SourceCatalogTests: XCTestCase {
    func testEverySourceAndProviderHasOneDeclarationInEstablishedOrder() {
        XCTAssertEqual(SourceCatalog.entries.map(\.source), HistorySource.allCases)
        XCTAssertEqual(SourceCatalog.entries.map(\.provider), Provider.allCases)
        XCTAssertEqual(Set(SourceCatalog.entries.map(\.source)).count, HistorySource.allCases.count)
        XCTAssertEqual(Set(SourceCatalog.entries.map(\.provider)).count, Provider.allCases.count)
        for descriptor in SourceCatalog.entries {
            XCTAssertEqual(SourceCatalog.provider(for: descriptor.source), descriptor.provider)
            XCTAssertEqual(SourceCatalog.source(for: descriptor.provider), descriptor.source)
        }
    }

    func testMetadataRegistryIsDerivedFromLocalCapabilitiesNotASecondSourceList() {
        XCTAssertEqual(LocalUsageCollectorRegistry.collectors.map(\.source), SourceCatalog.localSources)
        XCTAssertFalse(SourceCatalog.localSources.contains(.cursor))
        XCTAssertFalse(SourceCatalog.localSources.contains(.deepseek))
        XCTAssertEqual(SourceCatalog.codingAgentSources, HistorySource.codingAgents)
        for source in HistorySource.allCases {
            XCTAssertEqual(LocalUsageCollectorRegistry.displayName(for: source), SourceCatalog.descriptor(for: source).displayName)
            XCTAssertEqual(SourceHealth.roots(for: source), SourceCatalog.descriptor(for: source).roots())
        }
    }

    func testCapabilitiesDoNotInventUnavailableModelOrSkillMetrics() {
        XCTAssertFalse(SourceCatalog.descriptor(for: .cursor).capabilities.contains(.modelDetail))
        XCTAssertFalse(SourceCatalog.descriptor(for: .cursor).capabilities.contains(.hourlyUsage))
        XCTAssertFalse(SourceCatalog.descriptor(for: .qwen).capabilities.contains(.skills))
        XCTAssertTrue(SourceCatalog.descriptor(for: .copilot).capabilities.contains(.skills))
        XCTAssertFalse(SourceCatalog.descriptor(for: .copilot).capabilities.contains(.hourlyUsage))
        XCTAssertEqual(SourceCatalog.descriptor(for: .kimi).historyAuthority, .replaceConfirmedEmpty)
        XCTAssertEqual(SourceCatalog.descriptor(for: .codex).historyAuthority, .retainAbsent)
    }
}
