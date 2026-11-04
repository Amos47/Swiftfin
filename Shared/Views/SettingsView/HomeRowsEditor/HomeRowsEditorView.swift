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

/// Settings → Customize → Home screen rows: the server layout, edited as a working copy until Save. Leaving with
/// pending edits asks Save / Discard / Keep editing.
struct HomeRowsEditorView: View {

    private enum Confirmation: Identifiable {
        case reset
        case saveDefault
        case removeDefault

        var id: Self {
            self
        }
    }

    @ObservedObject
    var editor: HomeRowsEditor
    let isAdmin: Bool

    @Router
    private var router

    @State
    private var loadFailed = false
    @State
    private var confirmation: Confirmation?
    @State
    private var isLeavePromptPresented = false

    #if os(tvOS)
    /// Pick-up-and-move reordering with the remote: select a row to pick it up, up and down move it, select (or
    /// Back) drops it.
    @State
    private var isReordering = false
    @State
    private var heldKey: String?
    #endif

    #if os(iOS)
    @Environment(\.editMode)
    private var editMode
    #endif

    var body: some View {
        Form {
            if editor.loaded {
                rowsSection
                actionsSection
                if isAdmin {
                    adminSection
                }
            } else if loadFailed {
                Section {
                    Text(L10n.homeRowsLoadFailed)
                    Button(L10n.retry) {
                        Task { await load() }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(L10n.homeScreenRows)
        .task {
            if !editor.loaded {
                await load()
            }
        }
        .modifier(LeaveGuard(editor: editor, isPromptPresented: $isLeavePromptPresented) {
            router.dismiss()
        })
        #if os(tvOS)
        .onExitCommand(perform: isReordering ? {
            if heldKey != nil {
                heldKey = nil
            } else {
                isReordering = false
            }
        } : nil)
        #endif
        #if os(iOS)
        .toolbar {
            if editor.loaded, editor.rows.count > 1 {
                EditButton()
            }
        }
        #endif
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: {
                if !$0 {
                    confirmation = nil
                }
            }),
            titleVisibility: .visible,
            presenting: confirmation
        ) { confirmation in
            Button(confirmationTitle, role: confirmation == .saveDefault ? nil : .destructive) {
                Task { await perform(confirmation) }
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: { confirmation in
            switch confirmation {
            case .reset: Text(L10n.homeRowsResetMessage)
            case .saveDefault: Text(L10n.homeRowsSaveDefaultMessage)
            case .removeDefault: Text(L10n.homeRowsRemoveDefaultMessage)
            }
        }
    }

    // MARK: - Sections

    private var rowsSection: some View {
        Section {
            #if os(tvOS)
            Button(isReordering ? L10n.homeRowsReorderDone : L10n.homeRowsReorder) {
                isReordering.toggle()
                heldKey = nil
            }
            .disabled(editor.rows.count < 2 && !isReordering)
            #endif

            ForEach(editor.rows) { editorRow in
                ChevronButton {
                    #if os(tvOS)
                    if isReordering {
                        heldKey = heldKey == editorRow.key ? nil : editorRow.key
                        return
                    }
                    #endif
                    router.route(to: .homeRow(editor: editor, key: editorRow.key))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editorRowLabel(row: editorRow.row, provider: editor.provider(editorRow.row.provider)))
                            .foregroundStyle(.primary)
                        #if os(tvOS)
                        if heldKey == editorRow.key {
                            Label(L10n.homeRowsMoving, systemImage: "arrow.up.arrow.down")
                                .font(.footnote)
                                .foregroundStyle(.tint)
                        }
                        #endif
                        if let caption = caption(for: editorRow) {
                            Text(caption)
                                .font(.footnote)
                                .foregroundStyle(editor.errors[editorRow.key] != nil ? .red : .secondary)
                        }
                    }
                }
            }
            #if os(tvOS)
            .onMoveCommand { direction in
                    guard let heldKey else { return }
                    switch direction {
                    case .up: editor.move(key: heldKey, by: -1)
                    case .down: editor.move(key: heldKey, by: 1)
                    default: break
                    }
                }
            #endif
            #if os(iOS)
                .onMove { editor.moveRow(from: $0, to: $1) }
            .onDelete { offsets in
                for key in offsets.map({ editor.rows[$0].key }) {
                    editor.remove(key: key)
                }
            }
            #endif

            Menu {
                ForEach(editor.providers, id: \.id) { provider in
                    Button(provider.name) {
                        if let key = editor.add(providerID: provider.id) {
                            router.route(to: .homeRow(editor: editor, key: key))
                        }
                    }
                }
            } label: {
                Label(L10n.homeRowsAddRow, systemImage: "plus")
            }
            .disabled(editor.rows.count >= maxHomeRows)
        } footer: {
            VStack(alignment: .leading) {
                if editor.rows.count >= maxHomeRows {
                    Text(L10n.homeRowsAddRowFull)
                }
                if editor.hasPendingEdits {
                    Text(L10n.homeRowsUnsavedChanges)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button(L10n.save) {
                Task { await save() }
            }
            .disabled(!editor.hasPendingEdits || editor.isBusy)

            Button(L10n.homeRowsReset, role: .destructive) {
                confirmation = .reset
            }
            .disabled(editor.isBusy)
        } footer: {
            VStack(alignment: .leading) {
                if !editor.errors.isEmpty {
                    Text(L10n.homeRowsSaveFailed)
                }
                ForEach(Array((editor.errors[generalErrorsKey] ?? [:]).values).sorted(), id: \.self) { message in
                    Text(message)
                }
                if let generalError = editor.generalError {
                    Text(generalError)
                }
            }
            .foregroundStyle(.red)
        }
    }

    private var adminSection: some View {
        Section {
            Button(L10n.homeRowsSaveDefault) {
                confirmation = .saveDefault
            }
            Button(L10n.homeRowsRemoveDefault, role: .destructive) {
                confirmation = .removeDefault
            }
        }
        .disabled(editor.isBusy)
    }

    // MARK: - Helpers

    private var confirmationTitle: String {
        switch confirmation {
        case .saveDefault: L10n.homeRowsSaveDefault
        case .removeDefault: L10n.homeRowsRemoveDefault
        default: L10n.homeRowsReset
        }
    }

    private func caption(for editorRow: EditorRow) -> String? {
        if !editorRow.row.isAvailable || editor.provider(editorRow.row.provider) == nil {
            return L10n.homeRowsUnavailable
        }
        if let message = editor.errors[editorRow.key]?.values.first {
            return message
        }
        if !editor.validation(editorRow).isEmpty {
            return L10n.homeRowsNeedsSettings
        }
        if !editorRow.row.enabled {
            return L10n.homeRowsHidden
        }
        return nil
    }

    private func load() async {
        loadFailed = false
        do {
            try await editor.load()
        } catch {
            loadFailed = true
        }
    }

    private func save() async {
        if await editor.save() {
            Notifications[.homeRowsDidChange].post()
        }
    }

    private func perform(_ confirmation: Confirmation) async {
        let done = switch confirmation {
        case .reset: await editor.reset()
        case .saveDefault: await editor.saveAsDefault()
        case .removeDefault: await editor.removeDefault()
        }
        if done {
            Notifications[.homeRowsDidChange].post()
        }
    }
}

/// Asks Save / Discard / Keep editing when leaving with pending edits. The back button is replaced while there are
/// edits, and the settings sheet can't be swiped away, so no way out silently drops them.
struct LeaveGuard: ViewModifier {

    @ObservedObject
    var editor: HomeRowsEditor
    @Binding
    var isPromptPresented: Bool
    let leave: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(editor.hasPendingEdits)
            #if os(iOS)
            .interactiveDismissDisabled(editor.hasPendingEdits)
            .toolbar {
                if editor.hasPendingEdits {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPromptPresented = true
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                }
            }
            #else
            .onExitCommand {
                if editor.hasPendingEdits {
                    isPromptPresented = true
                } else {
                    leave()
                }
            }
            #endif
            // An alert, not a confirmation dialog: iOS shows dialogs as popovers that hide the Keep Editing button.
            .alert(L10n.homeRowsUnsavedChanges, isPresented: $isPromptPresented) {
                Button(L10n.save) {
                    Task { await choose(.save) }
                }
                Button(L10n.homeRowsDiscard, role: .destructive) {
                    Task { await choose(.discard) }
                }
                Button(L10n.homeRowsKeepEditing, role: .cancel) {}
            } message: {
                Text(L10n.homeRowsUnsavedMessage)
            }
    }

    private func choose(_ choice: LeaveChoice) async {
        guard !editor.isBusy else { return }
        if await editor.resolveLeave(choice) {
            if choice == .save {
                Notifications[.homeRowsDidChange].post()
            }
            leave()
        }
    }
}
