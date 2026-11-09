# Interface

The user requested a very minimal native utility. The main content is 380 × 320
points: one observed gear, two equally weighted shift buttons, shortcut hints,
and one connection status. It uses system type and semantic colors and follows
the Mac's appearance. The icon is a plain pair of opposing arrows.

Settings, connection details, and activity are available from the ellipsis menu.
Command–comma opens settings. Settings can be saved or cancelled. The main window
has no slogan, decorative gauge, gradient, repeated status cards, or permanent
debug console.

Connection status must distinguish controller input from trainer readiness:

| Condition | Main-window status |
| --- | --- |
| Game is closed | Open Zwift to connect |
| Controller is not paired/connected | Pair with Zwift |
| Software controller is selected for Power Source | Select your trainer |
| Controller is connected; Zwift has not enabled trainer shifting | Trainer not ready |
| Controller is connected and Zwift has enabled trainer shifting | Connected |

The gear is always read from the game log. Input may change this value even when
the trainer is absent, so a changing number must not suppress the trainer status.
The connection panel explains the correct Power Source / Resistance / Controls
assignments. The backend protocol and pulse scheduler are shared with the CLI.

Shift buttons retain explicit press/release, cancellation on deactivation, and
accessible single-press actions. Stable `shift-up` / `shift-down` accessibility
identifiers let the live test locate them without screen-coordinate assumptions.

## Research used

Reviewed on 2026-11-09:

- [Impeccable: distill](https://impeccable.style/docs/distill/) — remove repetition
  and keep occasional options available without showing them all at once.
- [Impeccable source](https://github.com/pbakaus/impeccable) — researched as an AI
  design tool; its browser editing/runtime tools were not needed by this Swift app.
- [UI Skills: Apple Native UI](https://www.ui-skills.com/skills/kemiljk/apple-native-ui)
  — native controls, semantic appearance, accessibility, and actual-device checks.
- [Apple: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
  — familiar commands, keyboard use, and coexistence with another app's window.

No design framework or external runtime dependency was added.
