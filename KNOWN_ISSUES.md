# Known issues

## Empty text inputs vanish from the capture

**Symptom.** A form section that contains an empty text box captures as a bare label. There is nothing in the output that distinguishes it from a section heading with no field under it, so a reader concludes the form asks for nothing there.

**Seen on.** An Anthropic job application (Greenhouse, captured 2026-08-07). The form has an `Additional Information` free-text box. The capture rendered:

```
Additional Information
Have you ever interviewed at Anthropic before?
[Toggle flyout]
```

which reads as a heading over a single dropdown. The free-text box between them is missing entirely. The same capture got `Why Anthropic?` right only by accident: that box has descriptive text next to it (`Add a cover letter or anything else you want to share.`) which came through as its own static-text node.

**Cause.** `AXHarvester.emit` (Sources/OverscrollAX/AXHarvester.swift:334) requires non-empty text:

```swift
guard let text = text(of: element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
```

`text(of:)` tries `AXValue`, then `AXTitle`, then description. An unfilled `AXTextArea` has an empty `AXValue`, no `AXTitle` (its label is a sibling node, not an attribute), and usually no description. So the element resolves to nothing and is dropped. `AXTextArea` is in `textRoles`, so the role is being collected correctly; it is the empty-value guard that removes it.

The same applies to an empty `AXTextField` and an unset `AXComboBox`.

**Why the guard exists.** Dropping empty nodes is right for the general case: accessibility trees are full of empty containers and spacers, and emitting them would bury the content. The guard is only wrong for roles where emptiness is itself the information, which is the text-entry roles.

**Fix.** For text-entry roles specifically (`AXTextArea`, `AXTextField`, `AXComboBox`), do not drop on empty. Fall back in order:

1. `AXPlaceholderValue` (`kAXPlaceholderValueAttribute`) — many web forms set it, and it is the most informative thing available.
2. A role marker, e.g. `[empty text area]` / `[empty text field]`, so the reader can see a fillable field exists.

Leave the guard as-is for every other role.

**Test to add.** A fixture with a heading, an empty `AXTextArea`, and a dropdown should produce three rows, not two. Worth a second fixture where the text area has a placeholder, asserting the placeholder is what gets emitted.

**Impact.** Anything captured from a form is affected, which is the case the form-roles work in `formRoles` was added to support. A capture that silently omits the fields a person still has to fill in is worse than one that omits nothing, because the omission is invisible: there is no gap in the output to notice.
