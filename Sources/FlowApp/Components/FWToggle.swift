//
// FWToggle.swift
// Flow
//
// Custom pill-shaped toggle switch. No native macOS nonsense.
//

import SwiftUI

struct FWToggle: View {
    @Binding var isOn: Bool
    var label: String?

    private let width: CGFloat = 44
    private let height: CGFloat = 24
    private let knobPadding: CGFloat = 2

    var body: some View {
        HStack {
            if let label {
                Text(label)
                    .font(.body)
                    .foregroundStyle(FW.textPrimary)

                Spacer()
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? FW.accent : FW.border)
                        .frame(width: width, height: height)

                    Circle()
                        .fill(.white)
                        .frame(width: height - knobPadding * 2, height: height - knobPadding * 2)
                        .padding(knobPadding)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FWToggle(isOn: .constant(true), label: "Enabled toggle")
        FWToggle(isOn: .constant(false), label: "Disabled toggle")
        FWToggle(isOn: .constant(true))
    }
    .padding()
    .background(FW.background)
}
