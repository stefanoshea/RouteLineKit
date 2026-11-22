import Foundation
import RouteLineKit
import SwiftUI

struct PlannerView: View {
    private enum Mode {
        case explore
        case draw
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var location = PlannerLocation()
    @State private var mode = Mode.explore
    @State private var drawingRevision = 0
    @State private var stroke: [Coordinate] = []
    @State private var drawing: ResolvedStroke?
    @State private var match: ResolvedStroke?
    @State private var showingDrawing = false
    @State private var matchMessage: String?
    @State private var matchTask: Task<Void, Never>?

    private var displayedRoute: ResolvedStroke? {
        showingDrawing ? drawing : match ?? drawing
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let shortWindow = verticalSizeClass == .compact || size.height < 440
            let showsSidebar = shortWindow && size.width >= 520
            let stacksControls = !showsSidebar && (shortWindow || dynamicTypeSize.isAccessibilitySize)

            map
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !showsSidebar && !stacksControls {
                        header.background(.background)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if stacksControls {
                        VStack(spacing: 0) {
                            Divider()
                            scrollableControls
                        }
                        .frame(height: size.height * 0.44)
                        .background(.background)
                    } else if !showsSidebar {
                        VStack(spacing: 0) {
                            Divider()
                            footer
                        }
                        .background(.background)
                    }
                }
                .safeAreaInset(edge: .leading, spacing: 0) {
                    if showsSidebar {
                        HStack(spacing: 0) {
                            scrollableControls
                            Divider()
                        }
                        .frame(width: min(340, size.width * 0.46))
                        .background(.background)
                    }
                }
        }
        .background(.background)
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if PlannerPathFixture.preloadsDrawing, stroke.isEmpty {
                completeStroke(PlannerPathFixture.stroke)
            }
        }
        #endif
        .onDisappear {
            cancelMatch()
            location.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                location.cancel()
            }
        }
    }

    private var map: some View {
        PlannerMap(
            isDrawing: mode == .draw, drawingRevision: drawingRevision,
            route: displayedRoute, location: location.position, onStrokeBegan: cancelMatch
        ) { samples in
            completeStroke(samples)
        }
        .overlay(alignment: .topTrailing) {
            if mode == .explore {
                Button {
                    location.recenter()
                } label: {
                    Image(systemName: location.isLocating ? "location.fill" : "location")
                        .font(.system(.body, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: .circle)
                }
                .accessibilityLabel(location.isLocating ? "Finding your location" : "Center on my location")
                .accessibilityValue(location.position == nil ? "" : "Location available on map")
                .accessibilityIdentifier("planner.location")
                .disabled(location.isLocating)
                .padding(12)
            }
        }
    }

    private var scrollableControls: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                Divider()
                footer
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Route Planner")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    modeButton("Explore", icon: "map", value: .explore, identifier: "planner.explore")
                    modeButton("Draw", icon: "pencil", value: .draw, identifier: "planner.draw")
                }
                VStack(spacing: 8) {
                    modeButton("Explore", icon: "map", value: .explore, identifier: "planner.explore")
                    modeButton("Draw", icon: "pencil", value: .draw, identifier: "planner.draw")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeButton(_ title: LocalizedStringKey, icon: String, value: Mode, identifier: String) -> some View {
        Button {
            if value == .draw {
                location.cancel()
                location.clearMessage()
            }
            mode = value
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .background {
                    Capsule().fill(mode == value ? Color.accentColor.opacity(0.17) : Color.secondary.opacity(0.08))
                }
                .overlay {
                    if mode == value {
                        Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let route = displayedRoute {
                routeSummary(route)
            } else {
                Text(mode == .draw ? "Trace your route on the map." : "Move the map to your starting point, then choose Draw.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("planner.hint")
            }

            if let message = location.message {
                Text(message)
                    .font(.footnote)
                    .accessibilityIdentifier("planner.location.status")
            }

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeSummary(_ route: ResolvedStroke) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    distance(route)
                    Spacer(minLength: 12)
                    routeSummaryLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    distance(route)
                    routeSummaryLabel
                }
            }

            if let matchMessage {
                Text(matchMessage)
                    .font(.footnote)
                    .accessibilityIdentifier("planner.match.status")
            }

            if match != nil {
                legend(route)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    routeActions
                    clearButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    routeActions
                    clearButton
                }
            }

            if match == nil {
                Text("Matching sends selected route points to Apple Maps for walking directions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var routeSummaryLabel: some View {
        let title: LocalizedStringKey
        if let match, !showingDrawing {
            title = match.segments.contains { $0.kind == .freehand } ? "Partial Apple Maps match" : "Apple Maps walking route"
        } else {
            title = "Drawn line"
        }
        return Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("planner.route.summary")
    }

    private func distance(_ route: ResolvedStroke) -> some View {
        let length = Measurement(value: route.distanceMeters, unit: UnitLength.meters)
        return Text(length, format: .measurement(width: .abbreviated, usage: .road))
            .font(.title2.weight(.semibold).monospacedDigit())
            .accessibilityIdentifier("planner.distance")
    }

    @ViewBuilder
    private func legend(_ route: ResolvedStroke) -> some View {
        if route.segments.contains(where: { $0.kind == .snapped }) {
            legendItem("Matched path", kind: .snapped)
        }
        if route.segments.contains(where: { $0.kind == .approximate }) {
            legendItem("Approximate match", kind: .approximate)
        }
        if route.segments.contains(where: { $0.kind == .freehand }) {
            legendItem(showingDrawing ? "Drawn line" : "Unmatched drawing", kind: .freehand)
        }
    }

    private func legendItem(_ title: LocalizedStringKey, kind: StrokeSegment.Kind) -> some View {
        let style = RouteStyle(kind: kind)
        return Label {
            Text(title)
        } icon: {
            Path { path in
                path.move(to: CGPoint(x: 2, y: 4))
                path.addLine(to: CGPoint(x: 24, y: 4))
            }
            .stroke(
                Color(uiColor: style.color),
                style: StrokeStyle(
                    lineWidth: 3, lineCap: kind == .approximate ? .butt : .round,
                    dash: style.dashPattern ?? [])
            )
            .frame(width: 26, height: 8)
            .accessibilityHidden(true)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var routeActions: some View {
        if matchTask != nil {
            Button {
                cancelMatch()
            } label: {
                HStack {
                    ProgressView()
                    Text("Cancel match")
                }
                .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("planner.cancel")
        } else if match != nil {
            Button {
                showingDrawing.toggle()
            } label: {
                Text(showingDrawing ? "Show path match" : "Show drawing")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("planner.compare")
        } else {
            Button {
                matchPaths()
            } label: {
                Text("Match walking paths")
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("planner.match.apple")
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            cancelMatch()
            drawingRevision += 1
            stroke.removeAll()
            drawing = nil
            match = nil
            matchMessage = nil
            showingDrawing = false
        } label: {
            Text("Clear")
                .frame(minWidth: 44, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("planner.clear")
    }

    private func completeStroke(_ samples: [Coordinate]) {
        let route = ResolvedStroke.freehand(samples)
        guard !route.segments.isEmpty, route.distanceMeters >= 1 else { return }
        cancelMatch()
        stroke = samples
        drawing = route
        match = nil
        matchMessage = nil
        showingDrawing = false
    }

    private func cancelMatch() {
        matchTask?.cancel()
        matchTask = nil
    }

    private func matchPaths() {
        cancelMatch()
        let samples = stroke
        matchMessage = nil
        matchTask = Task {
            do {
                let result = try await walkingRoute(for: samples)
                try Task.checkCancellation()
                match = result
                showingDrawing = false
            } catch {
                guard !Task.isCancelled else { return }
                matchMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn’t load nearby paths. Your drawing is still on the map."
            }
            matchTask = nil
        }
    }

    private func walkingRoute(for samples: [Coordinate]) async throws -> ResolvedStroke {
        #if DEBUG && targetEnvironment(simulator)
            if PlannerPathFixture.preloadsDrawing {
                return try await PlannerPathFixture.walkingRoute(for: samples)
            }
        #endif
        return try await RouteLineKit.walkingRoute(for: samples)
    }
}
