import SwiftUI

/// A text field whose value reaches its owner on Return or when the field is
/// left (focus loss, or the field going away), not on every keystroke.
///
/// A plain `TextField` writes each keystroke through its binding. For a setting
/// that an observer acts on at once that is the wrong shape: the custom WhisperKit
/// model fields are synced into the engine as they change, so each keystroke that
/// happened to form a valid value dropped the loaded model. Here the keystrokes
/// land in `draft`, and `commit` runs with the field's value once its editing is
/// over. That is per field: two fields edited one after the other are two
/// commits, and the owner sees the first change before the second. The owner
/// holds the draft, so a test can type into it and read it back; only the focus
/// state is the field's own, and a test drives focus loss through its `onChange`.
///
/// `value` is what the owner holds now. The field shows it until an edit starts,
/// and again whenever the owner changes it behind the field (a folder picker, a
/// Clear button): the owner's value wins over an edit in progress, because the
/// alternative is a field that shows one path while the setting holds another.
struct DraftTextField: View {
    let title: String
    let prompt: Text?
    let value: String
    @Binding var draft: String
    let commit: (String) -> Void
    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        value: String,
        draft: Binding<String>,
        prompt: Text? = nil,
        commit: @escaping (String) -> Void,
    ) {
        self.title = title
        self.prompt = prompt
        self.value = value
        _draft = draft
        self.commit = commit
    }

    var body: some View {
        // Read here so that this body observes the draft. An owner may keep it in
        // an `@Observable` object, and then the binding's getter otherwise runs
        // outside any body: a draft set from code (on appear, or when the owner's
        // value changes) would not repaint the field.
        let _ = draft // swiftlint:disable:this redundant_discardable_let
        TextField(title, text: $draft, prompt: prompt)
            .focused($isFocused)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in draft = newValue }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitIfEdited() }
            }
            .onSubmit { commitIfEdited() }
            // Clicking a button or switching the Settings tab need not take focus
            // from the field, so without this an edit would leave with the field.
            .onDisappear { commitIfEdited() }
    }

    /// An unchanged value is not handed over: every write re-runs the settings
    /// observers, and a field that was merely tabbed through has nothing to say.
    private func commitIfEdited() {
        guard draft != value else { return }
        commit(draft)
    }
}
