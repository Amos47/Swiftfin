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
    /// The focused row. While a row is held, focus stepping onto a neighbour moves the held row there instead.
    @FocusState
    private var focusedKey: String?
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
                    .disabled(isHolding)
                if isAdmin {
                    adminSection
                        .disabled(isHolding)
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
            // The editor outlives this screen; reload unless it holds unsaved edits to come back to.
            if !editor.hasPendingEdits {
                await load()
            }
        }
        #if os(tvOS)
        .onChange(of: focusedKey) { _, newKey in
            moveHeldRow(toward: newKey)
        }
        #endif
        .modifier(LeaveGuard(editor: editor, isPromptPresented: $isLeavePromptPresented, interceptExit: interceptExit) {
            router.dismiss()
        })
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
            .disabled((editor.rows.count < 2 && !isReordering) || isHolding)
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
                #if os(tvOS)
                .focused($focusedKey, equals: editorRow.key)
                #endif
            }
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
            .disabled(editor.rows.count >= maxHomeRows || isHolding)
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

    #if os(tvOS)
    /// Focus stepped from the held row onto a neighbour: swap the held row into that place and keep focus on it.
    private func moveHeldRow(toward newKey: String?) {
        guard let heldKey, let newKey, newKey != heldKey,
              let from = editor.rows.firstIndex(where: { $0.key == heldKey }),
              let to = editor.rows.firstIndex(where: { $0.key == newKey })
        else { return }
        editor.move(key: heldKey, by: to > from ? 1 : -1)
        focusedKey = heldKey
    }
    #endif

    /// Whether a row is picked up for moving (tvOS only).
    private var isHolding: Bool {
        #if os(tvOS)
        heldKey != nil
        #else
        false
        #endif
    }

    /// tvOS Back while reordering drops the held row first, then leaves reorder mode, before anything else.
    private func interceptExit() -> Bool {
        #if os(tvOS)
        if heldKey != nil {
            heldKey = nil
            return true
        }
        if isReordering {
            isReordering = false
            return true
        }
        #endif
        return false
    }

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
    /// Runs first on tvOS Back; true means it handled Back. One handler, so the order is certain.
    var interceptExit: () -> Bool = { false }
    let leave: () -> Void

    /// False while a row screen is pushed on top. The sheet takes its swipe-to-dismiss setting from this screen even
    /// then, and row screens hand typed text to the editor only when they close, so dismissing must stay blocked.
    @State
    private var isOnTop = true

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(editor.hasPendingEdits)
            #if os(iOS)
            .interactiveDismissDisabled(editor.hasPendingEdits || !isOnTop)
            .onAppear { isOnTop = true }
            .onDisappear { isOnTop = false }
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
                if interceptExit() {
                    return
                }
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
