import MapKit
import SwiftUI

/// Home, Work and other named places (spec §6.2): MapKit pin drop or "use current location".
/// Used in onboarding and in Settings → Places (with suggestions to name or dismiss).
struct PlacesView: View {
    let env: AppEnvironment
    var onboarding = false
    var onDone: () -> Void = {}

    @State private var places: [Place] = []
    @State private var editing: Place.Kind?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                row(.home, title: "Home")
                row(.work, title: "Work")
            } footer: {
                Text("Fengshui only notices arrivals and departures at your places. It never tracks a continuous route.")
            }
            Section("Other places") {
                ForEach(places.filter { $0.kind == .custom }) { p in
                    LabeledContent(p.name, value: "\(Int(p.radius)) m")
                }
                .onDelete { idx in
                    let ids = idx.map { places.filter { $0.kind == .custom }[$0].id }
                    Task { for id in ids { try? await env.places.delete(id) }; reload() }
                }
                Button("Add a place") { editing = .custom }
                    .accessibilityIdentifier("places.addCustom")
            }
            let suggested = places.filter { $0.kind == .suggested }
            if !suggested.isEmpty {
                Section("Suggested") {
                    ForEach(suggested) { SuggestionRow(env: env, place: $0, reload: reload) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if onboarding {
                Button("Continue") { onDone() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("places.continue")
            }
        }
        .navigationTitle("Places")
        .sheet(item: $editing) { kind in
            NavigationStack {
                PlaceEditor(env: env, kind: kind) { reload() }
            }
        }
        .task {
            if onboarding { _ = await env.location.requestAlwaysAuthorization() }
            reload()
        }
    }

    private func row(_ kind: Place.Kind, title: String) -> some View {
        let p = places.first { $0.kind == kind }
        return Button {
            editing = kind
        } label: {
            LabeledContent(title, value: p == nil ? "Set…" : "Set ✓")
        }
        .accessibilityIdentifier("places.set.\(kind.rawValue)")
    }

    private func reload() {
        places = (try? env.places.places()) ?? []
    }
}

extension Place.Kind: Identifiable { var id: String { rawValue } }

private struct SuggestionRow: View {
    let env: AppEnvironment
    let place: Place
    let reload: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(place.name).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Name this place", text: $name)
                Button("Save") { Task { try? await env.places.confirmSuggestion(place.id, name: name); reload() } }
                    .disabled(name.isEmpty)
                Button("Dismiss", role: .destructive) { Task { try? await env.places.dismissSuggestion(place.id); reload() } }
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Drop a pin on the map or use the current location; radius defaults to 150 m.
struct PlaceEditor: View {
    let env: AppEnvironment
    let kind: Place.Kind
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pin: CLLocationCoordinate2D?
    @State private var radius = 150.0
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Form {
            if kind == .custom {
                TextField("Name", text: $name).accessibilityIdentifier("placeEditor.name")
            }
            MapReader { proxy in
                Map(position: $camera) {
                    if let pin {
                        Marker(name.isEmpty ? kind.rawValue.capitalized : name, coordinate: pin)
                        MapCircle(center: pin, radius: radius).foregroundStyle(.blue.opacity(0.15))
                    }
                }
                .onTapGesture { pt in pin = proxy.convert(pt, from: .local) }
                .frame(height: 260)
            }
            Button("Use current location") {
                Task {
                    if let c = try? await env.location.currentCoordinate() {
                        pin = .init(latitude: c.lat, longitude: c.lon)
                        camera = .region(MKCoordinateRegion(center: pin!, latitudinalMeters: 800, longitudinalMeters: 800))
                    }
                }
            }
            .accessibilityIdentifier("placeEditor.current")
            Stepper("Radius \(Int(radius)) m", value: $radius, in: 100...500, step: 50)
        }
        .navigationTitle(kind == .custom ? "New place" : kind.rawValue.capitalized)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let pin else { return }
                    let title = kind == .custom ? name : kind.rawValue.capitalized
                    Task {
                        try? await env.places.save(name: title, kind: kind, lat: pin.latitude, lon: pin.longitude, radius: radius)
                        saved()
                        dismiss()
                    }
                }
                .disabled(pin == nil || (kind == .custom && name.isEmpty))
                .accessibilityIdentifier("placeEditor.save")
            }
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}
