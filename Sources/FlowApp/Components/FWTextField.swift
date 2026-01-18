//
// FWTextField.swift
// Flow
//
// Custom text field with bottom border focus state. Clean and minimal.
//

import SwiftUI

struct FWTextField: View {
    @Binding var text: String
    let placeholder: String
    var isSecure: Bool = false
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                } else {
                    TextField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                }
            }
            .textFieldStyle(.plain)
            .font(FW.fontMono)
            .foregroundStyle(FW.textPrimary)
            .focused($isFocused)
            .padding(.vertical, FW.spacing12)
            .padding(.horizontal, FW.spacing12)
            .background(FW.background)

            Rectangle()
                .fill(isFocused ? FW.accent : FW.border)
                .frame(height: isFocused ? 2 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .background(FW.background)
        .clipShape(RoundedRectangle(cornerRadius: FW.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: FW.radiusSmall)
                .strokeBorder(isFocused ? FW.accent.opacity(0.3) : FW.border, lineWidth: 1)
        }
    }
}

struct FWSecureField: View {
    @Binding var text: String
    let placeholder: String
    var onSubmit: (() -> Void)?

    @State private var showText = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: FW.spacing8) {
            Group {
                if showText {
                    TextField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                } else {
                    SecureField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                }
            }
            .textFieldStyle(.plain)
            .font(FW.fontMono)
            .foregroundStyle(FW.textPrimary)
            .focused($isFocused)

            Button {
                showText.toggle()
            } label: {
                Image(systemName: showText ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(FW.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, FW.spacing12)
        .padding(.horizontal, FW.spacing12)
        .background(FW.background)
        .clipShape(RoundedRectangle(cornerRadius: FW.radiusSmall))
        .overlay {
            RoundedRectangle(cornerRadius: FW.radiusSmall)
                .strokeBorder(isFocused ? FW.accent : FW.border, lineWidth: 1)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        FWTextField(text: .constant(""), placeholder: "Enter text...")
        FWTextField(text: .constant("Some value"), placeholder: "Enter text...")
        FWSecureField(text: .constant(""), placeholder: "sk-...")
        FWSecureField(text: .constant("secret123"), placeholder: "sk-...")
    }
    .padding()
    .background(FW.surface)
}
