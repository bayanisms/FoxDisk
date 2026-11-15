import SwiftUI

extension FileKind {
    var color: Color {
        switch self {
        case .folders: Color(red: 0.44, green: 0.72, blue: 0.65)
        case .media: Color(red: 0.87, green: 0.64, blue: 0.51)
        case .documents: Color(red: 0.55, green: 0.67, blue: 0.84)
        case .archives: Color(red: 0.76, green: 0.66, blue: 0.83)
        case .other: Color(red: 0.80, green: 0.76, blue: 0.58)
        }
    }
}

enum StoragePalette {
    private struct Swatch {
        let r: Double, g: Double, b: Double

        func blend(toward end: Swatch, by t: Double) -> Color {
            Color(red: r + (end.r - r) * t, green: g + (end.g - g) * t, blue: b + (end.b - b) * t)
        }
    }

    private static let green = Swatch(r: 0.40, g: 0.77, b: 0.52)
    private static let yellow = Swatch(r: 0.98, g: 0.84, b: 0.37)
    private static let red = Swatch(r: 0.95, g: 0.40, b: 0.35)

    static func position(bytes: Int64, smallest: Int64, largest: Int64) -> Double {
        guard largest > smallest, smallest > 0 else { return 0.5 }
        // Log ratios preserve visible differences across several orders of magnitude.
        let span = log1p(Double(largest - smallest) / Double(smallest))
        let offset = log1p(Double(min(largest, max(smallest, bytes)) - smallest) / Double(smallest))
        return offset / span
    }

    static func color(at position: Double) -> Color {
        if position <= 0.5 { return green.blend(toward: yellow, by: position * 2) }
        return yellow.blend(toward: red, by: (position - 0.5) * 2)
    }
}

struct StorageMapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Capsule().fill(LinearGradient(colors: [0.0, 0.5, 1.0].map(StoragePalette.color),
                                          startPoint: .leading, endPoint: .trailing)).frame(height: 6)
            HStack { Text("Smaller"); Spacer(); Text("Medium"); Spacer(); Text("Larger") }
                .font(.caption).foregroundStyle(.secondary)
        }.frame(width: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relative size in this map: green for smaller, yellow for medium, red for larger.")
    }
}

struct MapTile: Identifiable {
    var item: DiskItem?
    var bytes: Int64
    var name: String
    var id: String { item?.url.path ?? "" }
}

func partition(_ tiles: ArraySlice<MapTile>, in rect: CGRect) -> [(MapTile, CGRect)] {
    guard let first = tiles.first else { return [] }
    if tiles.count == 1 { return [(first, rect)] }
    let total = Double(tiles.reduce(Int64(0)) { $0 + $1.bytes })
    var sum = Double(first.bytes), count = 1
    while count < tiles.count - 1 {
        let next = sum + Double(tiles[tiles.startIndex + count].bytes)
        if abs(total / 2 - next) >= abs(total / 2 - sum) { break }
        sum = next
        count += 1
    }
    let horizontal = rect.width >= rect.height
    let (a,b) = rect.divided(atDistance: (horizontal ? rect.width : rect.height) * sum / total, from: horizontal ? .minXEdge : .minYEdge)
    return partition(tiles.prefix(count), in: a) + partition(tiles.dropFirst(count), in: b)
}

struct StorageMap: View {
    let items: [DiskItem]
    let selected: URL?
    let select: (DiskItem) -> Void
    let open: (DiskItem) -> Void
    var tiles: [MapTile] {
        let positive = items.prefix { $0.bytes > 0 }
        var result = positive.prefix(28).map { MapTile(item: $0, bytes: $0.bytes, name: $0.name) }
        let tail = positive.dropFirst(28)
        if !tail.isEmpty { result.append(MapTile(bytes: tail.reduce(0) { $0 + $1.bytes }, name: "\(tail.count) smaller items")) }
        return result
    }
    var body: some View {
        GeometryReader { proxy in
            let visible = tiles
            let sizes = visible.compactMap { $0.item?.bytes }
            let entries = partition(visible[...], in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                if entries.isEmpty { Text("No file data in this folder").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                ForEach(entries, id: \.0.id) { tile, rect in
                    let w = max(0, rect.width - 3), h = max(0, rect.height - 3)
                    let color = tile.item.map { item in
                        StoragePalette.color(at: StoragePalette.position(bytes: item.bytes, smallest: sizes.last ?? 0, largest: sizes.first ?? 0))
                    } ?? Color(white: 0.79)
                    RoundedRectangle(cornerRadius: 5).fill(color)
                        .overlay(alignment: .topLeading) {
                            if w > 45 && h > 23 {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(tile.name).font(.system(size: w > 160 ? 15 : 11, weight: .semibold)).lineLimit(1)
                                    if h > 46 { Text(sizeText(tile.bytes)).font(.system(size: 11, design: .monospaced)) }
                                }.foregroundStyle(Color.black.opacity(0.8)).padding(6)
                            }
                        }
                        .overlay { if let item = tile.item, selected == item.url { RoundedRectangle(cornerRadius: 5).strokeBorder(.black, lineWidth: 2) } }
                        .frame(width: w, height: h).clipped().contentShape(Rectangle())
                        .help("\(tile.name) · \(sizeText(tile.bytes))")
                        .onTapGesture(count: 2) { if let item = tile.item { open(item) } }
                        .onTapGesture { if let item = tile.item { select(item) } }
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}
