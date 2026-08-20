# Searchable multi-select interaction research

Research date: 2026-08-20

Question: when a terminal prompt combines filtering with a multi-select list,
how do established libraries resolve the fact that Space can either be query
text or toggle the highlighted item?

Only first-party documentation and source repositories are used below.

## Findings

### `prompts` (`autocompleteMultiselect`, JavaScript)

Up/Down move the highlighted option, Space always toggles it, and other
printable characters update the filter. Consequently a filter cannot contain
spaces. The implementation explicitly branches on `c === ' '`, calling the
toggle handler instead of the input handler.

Sources: [`autocompleteMultiselect` documentation](https://github.com/terkelg/prompts#autocompletemultiselectsame),
[`autocompleteMultiselect.js`](https://github.com/terkelg/prompts/blob/master/lib/elements/autocompleteMultiselect.js)

### `inquire` (`MultiSelect`, Rust)

Space is reserved for toggling the highlighted option; Up/Down navigate and
Enter submits. This likewise makes Space unavailable as filter text.

Sources: [`inquire` key bindings](https://github.com/mikaelmello/inquire/blob/main/KEY_BINDINGS.md),
[`MultiSelect` documentation](https://github.com/mikaelmello/inquire#multiselect)

### TTY::Prompt (`multi_select(filter: true)`, Ruby)

Letter and number keys update the dynamic filter, Space toggles, Up/Down
navigate, and Enter submits. Its documented filter input is deliberately
narrower than arbitrary text. Selected items remain selected when the filter
changes or is cleared.

Source: [`TTY::Prompt` multi-select filtering documentation](https://github.com/piotrmurach/tty-prompt#2637-filter)

### `inquirer-checkbox-plus-plus` (JavaScript)

Space always toggles and typing filters. It avoids the collision by restricting
search input to letters, digits, `.`, `-`, and `_`; spaces are explicitly
excluded.

Source: [`inquirer-checkbox-plus-plus` keyboard shortcuts](https://github.com/behnamazimi/inquirer-checkbox-plus-plus#keyboard-shortcuts)

## Comparison

The majority pattern reserves Space for toggling and accepts that queries cannot
contain spaces (`prompts`, `inquire`, TTY::Prompt, and
`inquirer-checkbox-plus-plus`).

## Decision

zcli follows that focusless terminal convention. The canonical interface is
`p.select(.{ .search = true, ... })` and
`p.multiSelect(.{ .search = true, ... })`.

Printable characters other than ASCII Space filter case-insensitively, Backspace
edits, Up/Down navigate, the Space key selects or toggles the highlighted
result, and Enter selects or commits. ASCII Space is not query text.
Multi-select choices remain selected when filtering hides them.
