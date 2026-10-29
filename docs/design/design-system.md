# Roll design system

One brand across every screen: warm paper, ink, one accent. Code lives in `App/DesignSystem/`:
`Tokens.swift` holds the values and `Components.swift` holds the pieces built from them. Views use those and never
raw colors, system tints (`.blue`, `.tint`, `.secondary`), `List` insets, or `ContentUnavailableView`.

The reference is the Ask Roll prototype, `docs/design/ask-roll/prototype.html`.

## Principles

1. **Paper and ink.** Each screen is a paper page. Content sits on white cards with a 1 pt hairline and a soft,
   low shadow. Text is ink, ink2, or ink3, nothing else.
2. **One main action per screen.** It is an ink capsule (`.rollPrimary`). Anything next to it is a card capsule
   (`.rollSecondary`). Ember (`.rollDestructive`) is only for the pile's action once confirmed.
3. **Color means something.** Ember is the pile's action (delete, squish) and the brand. Green is keep. Blue is
   album. Nothing is colored for decoration.
4. **Say why.** A result carries a sticker that explains it ("Matched by what's on screen", "Learns from every
   swipe"). Sizes are always "about" (ADR-0002). Times and counts shown are measured, never staged.
5. **The same conversation.** Search, swipe, and apply are steps of one flow. The composer turns into the action
   bar, and that turns into "Review & apply". Nothing jumps to a different-looking screen.
6. **Motion settles.** `Roll.Motion.ease` is for layout and reveals, `spring` for things arriving, `exit` for
   cards leaving. All of it respects Reduce Motion.

## Tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| paper | #F6F4EF | #11110F | page background, nav and tab bars |
| card | #FFFFFF | #1D1C1A | cards, composer, rows, circle buttons |
| well | #EDEAE3 | #262522 | placeholders, tracks, icon tiles |
| ink | #141414 | #F4F2EC | text, primary button, mark |
| ink2 | #6E6A62 | #A39E94 | secondary text |
| ink3 | #A8A39A | #6D6961 | section labels, placeholders, inactive tabs |
| onInk | #F6F4EF | #141414 | text on ink |
| hairline | ink 8% | white 10% | every border, 1 pt |
| ember | #FF5A36 | | brand accent, the pile's action |
| keep | #2FB45A | | keep |
| album | #2F7CF6 | | add to album |

- **Type:** SF Pro with Dynamic Type.
  - `display`: large title, bold, −0.9 tracking.
  - `title`: title 2, bold, −0.4.
  - `headline`, `body`, `callout`, and `subhead` follow the system sizes.
  - `label`: footnote, semibold. Used for chips, stickers, and tags.
  - `eyebrow`: caption 2, semibold, uppercase, +1.1 tracking.
  - `figure`: monospaced digits.
- **Radii:** cell 12, photo 18, card 20, deck 24, panel 28. Pills are capsules. Always use continuous corners.
- **Sizes:** control 44, composer 56, chip 34, sticker 26, circle button 36, avatar 28.
- **Spacing:** 4, 8, 12, 16, 20, 24, 32. The page margin is 20.
- **Shadow:** one soft shadow, black 5% with radius 14 and y 5. The lifted version is 12% with radius 22 and
  y 10, used for the top swipe card.

## Components

| Component | Where |
|---|---|
| `RollMark(size:busy:)` | avatar of Roll's turns, empty states, onboarding |
| `.rollPage()` | every screen's background |
| `.rollCard()` | any raised surface |
| `.rollPrimary` / `.rollSecondary` / `.rollDestructive` / `.roll(_:fullWidth:)` | buttons |
| `.rollCircle` | back, undo, close |
| `.rollText` | text buttons ("Not now") |
| `RollChip` | refinements and filters (toggles) |
| `RollWrap` | lays chips out in wrapping rows, so none is cut off or scrolled away |
| `RollSticker` | why Roll found or did something |
| `VerdictTag` | a swipe's outcome on the card |
| `SectionLabel` | eyebrow above a group |
| `RollGroup` + `RollRow` | lists: rows on one card, hairline dividers |
| `RollNotice` | model status, recovery, access, anything that needs attention |
| `RollEmptyState` | empty, loading, or blocked screens |
| `RollProgressBar` | download and scan progress |
| `StatusLine` | what Roll is doing; ends with a check and a measured time |
| `DoneRing` | the closing ring after applying |
| `ThumbFan` | suggestion cards |
| `RollAppearance.apply()` | nav and tab bars, switches, and alerts in brand (called at launch) |
