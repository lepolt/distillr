import SwiftUI

/// Photos-style translucent info card: camera and lens on top, resolution
/// and file info beneath, then a divider and the exposure row.
struct PhotoInfoCard: View {
    let details: PhotoDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let cameraModel = details.cameraModel { Text(cameraModel) }
                    if let lensModel = details.lensModel { Text(lensModel).lineLimit(1) }
                }
                Spacer(minLength: 24)
                if let whiteBalance = details.whiteBalance {
                    Text("WB \(whiteBalance)")
                        .font(.caption2)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                if let text = details.megapixelsText { Text(text) }
                if let text = details.dimensionsText { Text(text) }
                if let text = details.fileSizeText { Text(text) }
                Spacer(minLength: 0)
                if let format = details.format {
                    Text(format)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)

            let items = details.exposureItems
            if !items.isEmpty {
                Divider()
                HStack {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Spacer(minLength: 8) }
                        Text(item)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize()
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
