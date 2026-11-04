//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import HomeRowsCore
import SwiftUI

// Personal fork: Custom Home Rows.

/// One row of the rows editor: show on home, title, and one control per provider setting.
struct HomeRowView: View {

    @ObservedObject
    var editor: HomeRowsEditor
    let key: String

    @Router
    private var router

    @State
    private var title = ""

    private var editorRow: EditorRow? {
        editor.rows.first { $0.key == key }
    }

    var body: some View {
        Form {
            if let editorRow {
                content(editorRow)
            }
        }
        .navigationTitle(editorRow.map { editorRowLabel(row: $0.row, provider: editor.provider($0.row.provider)) } ?? "")
        .onAppear {
            title = editorRow?.row.title ?? ""
        }
        .onDisappear {
            commitTitle()
        }
        .onChange(of: editorRow == nil) { _, isGone in
            if isGone {
                router.dismiss()
            }
        }
        #if os(iOS)
        // Typed text reaches the editor when this screen goes away, so the sheet can't be swiped down from here:
        // going back to the rows list commits it, and the list asks before dropping edits.
        .interactiveDismissDisabled()
        #endif
    }

    @ViewBuilder
    private func content(_ editorRow: EditorRow) -> some View {
        let provider = editor.provider(editorRow.row.provider)
        let localErrors = editor.validation(editorRow)
        let serverErrors = editor.errors[key] ?? [:]

        Section {
            Toggle(L10n.homeRowsShowOnHome, isOn: Binding(
                get: { editorRow.row.enabled },
                set: { editor.setEnabled(key: key, $0) }
            ))

            TextField(L10n.title, text: $title, prompt: Text(L10n.homeRowsDefaultTitle))
                .onSubmit(commitTitle)
                .submitLabel(.done)
        } footer: {
            VStack(alignment: .leading) {
                if let description = provider?.description, !description.isEmpty {
                    Text(description)
                }
                if let message = serverErrors["title"] {
                    Text(message).foregroundStyle(.red)
                }
            }
        }

        if let provider {
            Section {
                ForEach(provider.fields(), id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        control(for: field, row: editorRow.row)
                        if let message = serverErrors[field.key] ?? localErrors[field.key]?.displayTitle {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }

        Section {
            Button(L10n.homeRowsRemoveRow, role: .destructive) {
                editor.remove(key: key)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private func control(for field: HomeRowField, row: HomeRowInstance) -> some View {
        let value = field.effectiveValue(in: row.config)

        switch field.kind {
        case .boolean:
            Toggle(field.label, isOn: Binding(
                get: { value?.bool ?? false },
                set: { editor.setValue(key: key, setting: field.key, .bool($0)) }
            ))
        case .integer:
            integerControl(field, value: value?.int ?? field.min ?? 0)
        case .string:
            HomeRowTextField(label: field.label, maxLength: field.maxLength, initial: value?.string ?? "") { text in
                editor.setValue(key: key, setting: field.key, text.isEmpty ? nil : .string(text))
            }
        case .enumeration:
            Picker(field.label, selection: Binding(
                get: { value?.string ?? "" },
                set: { editor.setValue(key: key, setting: field.key, .string($0)) }
            )) {
                if value?.string == nil || !field.isOption(value ?? .null) {
                    Text(L10n.none).tag("")
                }
                ForEach(field.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .multiEnumeration:
            let selected = Set(value?.array?.compactMap(\.string) ?? [])
            ChevronButton(
                field.label,
                content: field.options.filter { selected.contains($0.value) }.map(\.label).joined(separator: ", ")
            ) {
                router.route(to: .homeRowOptions(editor: editor, key: key, field: field))
            }
        }
    }

    @ViewBuilder
    private func integerControl(_ field: HomeRowField, value: Int) -> some View {
        let range = (field.min ?? 0) ... max(field.max ?? 10000, field.min ?? 0)
        let binding = Binding(
            get: { value },
            set: { editor.setValue(key: key, setting: field.key, .number(Double($0))) }
        )
        // Small ranges step; wide ones (such as cutoff days, 0...3650) take a typed number, clamped to the range.
        if range.count <= 100 {
            #if os(tvOS)
            Picker(field.label, selection: binding) {
                ForEach(Array(range), id: \.self) { Text($0, format: .number).tag($0) }
            }
            #else
            Stepper(value: binding, in: range) {
                LabeledContent(field.label, value: "\(value)")
            }
            #endif
        } else {
            HomeRowNumberField(label: field.label, range: range, initial: value) { binding.wrappedValue = $0 }
        }
    }

    private func commitTitle() {
        guard let current = editorRow?.row.title ?? Optional(""), current != title else { return }
        editor.setTitle(key: key, title)
    }
}

/// A whole number typed in, clamped to `range`, committed when editing ends.
struct HomeRowNumberField: View {

    let label: String
    let range: ClosedRange<Int>
    let initial: Int
    let commit: (Int) -> Void

    @State
    private var text = ""

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onAppear { text = String(initial) }
                .onSubmit(apply)
                .onDisappear(perform: apply)
        }
    }

    private func apply() {
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = String(initial)
            return
        }
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        text = String(clamped)
        if clamped != initial {
            commit(clamped)
        }
    }
}

/// A text setting that commits when editing ends, so trimming doesn't eat spaces while typing.
struct HomeRowTextField: View {

    let label: String
    let maxLength: Int?
    let initial: String
    let commit: (String) -> Void

    @State
    private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .onAppear { text = initial }
            .onSubmit { commit(trimmed) }
            .onDisappear {
                if trimmed != initial {
                    commit(trimmed)
                }
            }
    }

    private var trimmed: String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return maxLength.map { String(value.prefix($0)) } ?? value
    }
}

/// A pick-many setting: checkmarks, kept in the server's option order.
struct HomeRowMultiOptionView: View {

    @ObservedObject
    var editor: HomeRowsEditor
    let key: String
    let field: HomeRowField

    private var selected: Set<String> {
        let row = editor.rows.first { $0.key == key }?.row
        return Set(row.flatMap { field.effectiveValue(in: $0.config)?.array?.compactMap(\.string) } ?? [])
    }

    var body: some View {
        Form {
            Section {
                ForEach(field.options, id: \.value) { option in
                    Button {
                        var next = selected
                        if next.contains(option.value) {
                            next.remove(option.value)
                        } else {
                            next.insert(option.value)
                        }
                        let ordered = field.options.map(\.value).filter(next.contains)
                        editor.setValue(key: key, setting: field.key, .array(ordered.map(JSONValue.string)))
                    } label: {
                        HStack {
                            Text(option.label).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(option.value) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                if let minItems = field.minItems, selected.count < minItems {
                    Text(L10n.homeRowsErrorPickAtLeastOne).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(field.label)
        #if os(iOS)
        .interactiveDismissDisabled(editor.hasPendingEdits)
        #endif
    }
}
