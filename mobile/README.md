# Clubline mobile UI

Static, navigable Flutter presentation of the Clubline League Management App. The default entry point uses in-memory sample data. It does not initialize a backend, database, token store or connectivity service. No Firebase or Supabase integration is used.

## Run

From this folder run `flutter pub get`, then `flutter run`. The existing Android runner is included. The project requires Dart 3.12-compatible Flutter.

The app opens on Fixtures. Five tabs lead to Fixtures, Standings, Club, Store and Profile. Profile includes sign-in/sync previews and a role selector. Organizer/admin roles expose scoring drafts; manager/admin roles expose roster management. These are presentation controls, not authorization.

## Screens and interactions

- Fixtures: sport/league selector, date navigation, upcoming/live/results filters, match detail.
- Match: score panel, sample event history, information tab, organizer score draft.
- Standings: table, qualification and tie-break explanation.
- Club: searchable squad, player detail, overview and sample registration history.
- Manage roster: transfer/loan/release draft, player/squad selection, loan end date.
- Store: category/search filters, local merchandise illustrations, product variants/stock states.
- Bag and checkout: quantity updates, removal, WELCOME10 sample discount, sample receipt.
- Profile/sign-in/sync: role preview, validated sign-in layout, simulated sync states.

All changes reset on restart. Checkout does not charge or create orders. Sign-in does not authenticate. Sync does not upload data. Examples are dated 17 October 2026.

## Code map

`lib/main.dart` starts `presentation/clubline_app.dart`. `lib/presentation/` contains screen groups, shared Ocean Glass widgets, typed sample models and local cart state. `sample_data.dart` is the replacement point for backend-fed view models. Keep HTTP/JSON outside widgets when integrating FastAPI.

The pre-existing `lib/app.dart`, `lib/core/`, `lib/features/` and `lib/widgets/` remain as reference for future integration; they are not imported by the static entry point. Their packages remain in pubspec to keep reference code/tests compilable. One stale unsupported `fixture` constructor argument in that code was removed to restore analyzer compatibility.

## Design and reusable components

Source: Stitch project `15667412113181260169`, Ocean Glass screen family. The app follows exported fixtures/club/checkout layouts: ocean gradient (#005F8C → #008EC4 → #A8CADB → #E8F0F5), translucent white cards, 24px radii, Inter typography, navy text, blue actions and five navigation destinations. Content is adapted to `../schema.sql`; see [SCHEMA_UI_MAP.md](SCHEMA_UI_MAP.md).

Five files from `C:/Users/Administrator/Desktop/competition/lib/` are vendored under `lib/toolkit/`: app_tokens, pressable, app_chip, search_field and section_header. Source comments are preserved. There is no path dependency on the toolkit folder. The design follows its handbook's UI/data boundaries, simple mobile navigation, ephemeral local state, and scroll/text accessibility patterns.

Inter is bundled in `assets/fonts/` with its SIL Open Font License. Merchandise is drawn locally. The club hero uses a local gradient treatment in place of a remote photograph.

## Verify

```sh
flutter analyze
flutter test
flutter test tool/render_previews.dart
```

The last command exports five 390×844 screenshots to `build/ui-previews/`. Tests cover tabs, filters, discounted checkout, roster search/draft, stock arithmetic and 320px layouts at 1.4× text. Retained backend tests use fakes.
