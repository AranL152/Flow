//
// FWSegmentedControl.swift
// Flow
//
// Custom segmented picker with sliding indicator. Fuck native controls.
//

import SwiftUI

struct FWSegmentedControl<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selection == option ? FW.textPrimary : FW.textSecondary)
                        .padding(.horizontal, FW.spacing16)
                        .padding(.vertical, FW.spacing8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: FW.radiusSmall - 2)
                                    .fill(FW.surface)
                                    .matchedGeometryEffect(id: "selection", in: animation)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: FW.radiusSmall)
                .fill(FW.background)
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selected = "Quality"

        var body: some View {
            FWSegmentedControl(
                selection: $selected,
                options: ["Quality", "Balanced", "Fast"],
                label: { $0 }
            )
            .padding()
            .background(FW.surface)
        }
    }

    return PreviewWrapper()
}
