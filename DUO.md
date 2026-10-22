# Caloma on iPhone Duo

What changed overnight for iPhone Duo. Nothing is committed: review it with `git diff` and
`git status` (the new files are in `Caloma/Features/Duo/`). Nothing was compiled; read the
"Check first" list before building.

## What changed, file by file

New, in `Caloma/Features/Duo/`:

- `DuoGrid.swift`: `DuoAdaptiveGrid`, the old `.adaptive(minimum:)` grid when flat, and an even
  number of equal columns when partly folded (Book or Laptop). `ParentChoreTap`, the parent's
  check (done, approve, undo) shared by the new screens.
- `DuoKidPocket.swift`: Kid View on the outer display (Closed).
- `DuoChoreChart.swift`: the ring row for Chores (Open tall) and the chore chart (Open wide).
- `DuoChoresBesideRewards.swift`: chores beside the store (Book).
- `DuoAfterSchoolStation.swift`: the after-school station (Laptop).
- `DuoFamilyBoard.swift`: the Family Board glance board (Tent) and its Add a Note sheet.

Changed:

- `App/CalomaApp.swift`: `.hearthDuoPose()` on the scene's root.
- `Features/Home/HomeView.swift`: Laptop shows the station; a Family Board toolbar button
  (compact width) opens the glance board; the kids grid is even when folded.
- `Features/Chores/ChoresView.swift`: Open wide shows the chore chart, with Assign in the
  toolbar; Today on iPhone has the ring row at the top (tap a ring to filter to that kid); each
  kid's section shows their avatar instead of a dot; partly folded, the iPad-style board and
  Needs Your OK get a page each instead of a fixed 320 pt column.
- `Features/KidView/KidModeView.swift`: on the outer display Kid View is the pocket view; job
  and kid-picker grids are even when folded.
- `Features/Rewards/RewardsView.swift`: Book shows chores beside the store; grids even when
  folded. (The toolbar, sheet and alert moved up a level, unchanged.)
- Even grids when folded (`DuoAdaptiveGrid`): `KidStoreView`, `KidListPage`, `ListsView`,
  `ControlTiles` (DeviceGrid), `HomeShortcuts`, `ControlView`, `ControlSections`.
- Toolbar items with a title and a symbol, so they show on the rail: Edit in
  `HomeTaskDetailView`, `RotationDetailView`, `EventDetailView` and `KidDetailView`; Today in
  `CalendarView`; Family in `Components.swift` (`familyToolbarButton`, currently unused).

## How each pose behaves now

- **Standard** (other iPhones, iPad, iOS 26, inner portrait): as before, plus the ring row on
  Chores › Today (iPhone) and the Family Board button on Home (iPhone).
- **Closed (outer display), in Kid View**: the kid's ring and points, then today's chores as
  64 pt rows. Tap a row to finish it (photo chores open the camera; chores that need an OK wait
  for one). The only toolbar item is Switch Person: the other kids, and Parent (the usual Face ID
  or passcode to leave). The kid is remembered above the pose, so opening the phone carries on.
- **Open tall** (inner portrait): Chores › Today shows every kid's ring in three columns, then
  each kid's chores with their avatar. Tap a check to check it off. Standard bars.
- **Open wide** (inner landscape): Chores becomes the chore chart. Rooms (and All Rooms) on the
  leading pane; the chosen room's week, Mon to Sat, on the trailing pane, one avatar per day
  (dim until done, a check when done, orange while waiting). Today's column is outlined. Tap a
  day up to today to check it off or undo it. Tap a chore name, then Assign (rail) to open its
  editor where the people are picked. New Chore is on the rail too.
- **Book**: Rewards becomes a spread. Left page: a kid picker and that kid's chores today, with
  their spendable points. Right page: the store for that kid, with points at the top and "N
  stars to go" on rewards out of reach. A parent's check approves at once, so both pages' points
  move together.
- **Laptop**: Home becomes the station. Upright half: each kid's ring, what's left on the
  calendar today, and tonight's dinner from BigTable (Hearth+). Flat half: every kid's chores as
  big tiles, two across; tapping one is the kid's own "I did it" (waits for an OK if the chore
  asks).
- **Tent**: Home › Family Board (toolbar). Full screen in Caloma's color, screen kept awake: each
  kid's ring, the next timed event (today or tomorrow) and tonight's dinner. Close, Kid View and
  Add a Note are on the rail. Add a Note draws a wall note for the people picked.
- Partly folded anywhere: grids use an even number of columns.

## How to test in the iPhone Duo simulator

1. Run Caloma on the iPhone Duo simulator (iOS 27.1). Use a family with two or three kids, some
   chores today, a few rooms, a few rewards, an event later today. For dinner, BigTable on the
   same simulator with a plan for today, and Hearth+ (screenshot mode unlocks everything).
2. **Closed**: open Kid View for a kid, then close the device (Device › Fold menu or the
   simulator's posture control). Check the big rows, the ring filling, Switch Person, Parent.
3. **Open tall**: open the device in portrait. Chores › Today: three rings across, tap one to
   filter, tap checks.
4. **Open wide**: rotate to landscape. Chores: rooms on the left, week on the right, today
   outlined, Assign and New Chore on the trailing rail. Tap a day, a chore name, then Assign.
5. **Book**: fold partly with the fold vertical. Rewards: chores left, store right. Check a
   chore and watch both points figures move.
6. **Laptop**: fold partly with the fold horizontal and set it down. Home: afternoon on top,
   tiles below in two columns. Tap a tile.
7. **Tent**: on Home, tap Family Board (on the rail when closed). Check Kid View and Add a Note.
8. In Book and Laptop, look at Kid View, Rewards, Lists and Control: grids should split
   between columns, never through a card.

## Skipped, and why

- **"Kid View" and the Family Board button on the iPad**: the glance board button only shows in
  compact width, so the iPad keeps one "Family Board" (Kiosk Mode, in the Kid View menu).
- **Device checks left in place**: `KidViewButton`, `FamilyView` and the onboarding finish step
  use `userInterfaceIdiom == .pad` to offer Kiosk Mode only on iPad. That's a product rule
  (a wall iPad), not layout, so I left it. `KioskPresence` and `FaceEnrollment` read the window
  scene's screen for brightness, not layout.
- **Fixed widths kept**: the 320 pt Needs Your OK column on the regular-width chore board (now
  a fold page when folded), the 340 pt jar column in the kid's store on regular width, and the
  Kiosk's 112/300/330 pt columns (iPad wall only). They could crowd the inner display in
  landscape; worth a look in the simulator.
- **Custom bars kept**: Kid View's kid pills and Parent button (deliberate full-screen kid
  layout), Approve All at the bottom of Needs Your OK (a full-width prominent action), and the
  list editor's add bar (an input field).
- **Two-level screens**: More (Control, Home Care, Whiteboard) only pushes on iPhone. On regular
  width they're tabs already, so I didn't add a split.
- **Assign** opens the chore's editor; there's no separate quick-assign sheet.
- **Live Activity or widgets for the Duo**: not needed for these designs; none added.

## Check first (not compiled)

- `onGeometryChange(for:) { } action: { }`, `HearthFoldSplit`, `HearthFoldOverlay` and
  `HearthGlanceBoard` are used as the codebase and HearthDuo.swift already use them.
- `GridItem(.flexible(), spacing:, alignment:)` with an optional alignment in `DuoGrid.swift`.
- `ToolbarItemGroup(placement: .primaryAction)` inside `HearthGlanceBoard`'s `actions`.

## Decisions to confirm

1. **Family Board (Tent) is free.** It's a read-only glance, so it isn't behind Caloma Plus like
   the iPad wall. Add a Note is behind Caloma Plus (it's a wall note, like the whiteboard's).
2. **Add a Note** saves a wall note (`keep: .today`, pinned to the whiteboard), from nobody in
   particular. Without a wall iPad, it only shows in the Whiteboard tab's list. A plain text note
   or a calendar note would need a new model and a CloudKit schema change, so I didn't add one.
3. **Book is on Rewards** and **Laptop is on Home**. They could live on other tabs instead.
4. **The chore chart's week is Mon–Sat** (from the design). Sunday chores don't show there, and on
   a Sunday no column is outlined (it shows the week just ending).
5. **The chore chart is the Chores tab in Open wide**, replacing the This Week list in that pose.
   Today / This Week and the kid filter aren't on it.
6. **Kid taps on the station and pocket view** count as the kid's own (they wait for an OK when
   the chore needs one); parent taps on Chores, the chart and the Book page approve at once.
7. Chores › Today's kid sections now show an avatar instead of a colored dot, on every iPhone.

## Review (overnight)

A second pass over every changed and new file, reading each symbol back to its definition.
Still not compiled.

### What I checked

- Every symbol the new code uses exists with that name, labels, type and access:
  `Family.markDone/approve/undo`, `FamilySnapshot` (items, progress, balance, spendable),
  `BoardItem`/`ItemStatus`, `ChoreRow` and `PointsLabel` (internal, labels match), `KidTodayCard`,
  `MemberAvatar`, `ProgressRing`, `ChoreCheck`, `IconTile`, `TagLabel`, `Card`, `CardList`,
  `EmptyCard`, `HeaderTitle`, `colorHeader`, `CameraPicker`, `PhotoTools.jpeg`, `KidPressStyle`,
  `RewardTile`, `RewardMath.check`/`RewardCheck`, `CalendarMath.occurrences/order/timeLabel`,
  `HearthLink.dinner(on:)`/`hasLockedMealPlan`, `MealArtwork`, `PencilCanvas`, `hasInk`,
  `WallNote.init`, `WallNotePaper`, `SheetDoneButton`/`SheetCancelButton`, `CalomaPlus.isUnlocked`,
  `CalomaPlus.whiteboard`, `hearthPaywall(isPresented:feature:)`, `router.openKidView()`,
  `Button(_:menuIcon:action:)`, `\.accent`, and the HearthDuo API.
- The flagged spots:
  - DuoGrid.swift:26–41: the `onGeometryChange(for:) { } action: { }` form is the one KidModeView
    already uses. `GridItem(_:spacing:alignment:)` takes `Alignment?`, so passing nil is fine.
  - DuoFamilyBoard.swift:44–57: `.tint(.white)` is on the `HearthGlanceBoard` view, not on
    toolbar content. `ToolbarItemGroup(placement: .primaryAction)` is valid in the
    `@ToolbarContentBuilder` actions. OK.
  - ChoresView.swift:211–265: `wideBoard` is `@ViewBuilder` with an if/else, and `boardColumns`
    returns one ScrollView. The iPad layout (board plus 320 pt Needs Your OK) is unchanged when flat.
  - RewardsView.swift:31–150 and HomeView.swift:28–100: the toolbar, the reward editor sheet, the
    Mark Reached alert and the Family Board cover are all still there, one level up. Both
    branches return a single view.
- Chores: parent taps (Chores, the chart, Book) go through `ParentChoreTap`, the same as
  `ChoresView.toggle`. Open becomes approved with points, waiting becomes approved, done is
  undone with its points removed. Kid taps (pocket view, station) are `markDone(byParent: false)`,
  the same as Kid View, so they wait for an OK when the chore asks for one. Points come only from
  `Family.award`, so they stay right.
- Add a Note inserts an existing `WallNote` (already a CloudRecord type). No CloudKit schema change.
- Caloma Plus gating uses `CalomaPlus.isUnlocked` and `.hearthPaywall(feature:)`, the same as
  KidViewButton.
- Dinner text only comes from `HearthLink.dinner(on:)`. That reads BigTable's plan through
  HearthKit and is nil without Hearth+. The locked teaser doesn't show the meal.
- iPad: every new mode is behind a Duo pose, and iPad is always `.standard`. Kid View's menu and
  Kiosk Mode are untouched, and the Family Board button only shows in compact width.
- No banned APIs, and no UIScreen or idiom checks in the new code.
- `swiftparse.py`: 25 files, 0 errors.

### What I fixed

- DuoAfterSchoolStation.swift:166: the station's tile half (a ScrollView of synced chores) had
  no pull to refresh. Added `.refreshesFromICloud()` (AGENT.md iCloud rule).
- DuoChoreChart.swift:176: the week's date range was `.secondary` inside a block made white for
  the color header, which overrode the white and made it gray on the rose. It's now white at 85%,
  like `HeaderTitle`'s subtitle.

### Remaining risks

- HearthDuo.swift (shared, not edited): the pose is measured in a background at the scene root,
  outside any NavigationStack. Whether `toolbarVerticalEdge` is non-nil there decides `.outer`
  and `.openWide`. Kid View's pocket mode also depends on that value reaching the Kid View
  full-screen cover. Check both in the simulator first.
- KidModeView: on the outer display Kid View now shows a navigation bar (Switch Person). Folding
  and unfolding swaps between the pocket view and `KidDayView`. The kid stays the same, but the
  celebration and page state reset.
- Book left page: the "Today" line and points sit near the top of the color header in the text
  color. Check that it's readable in Light Mode.

### Decisions for Steve

- The three-ring row (`DuoTodayRings`) and the kid avatars on Chores › Today show on every
  iPhone, not just the Duo. The ring row filters the same way as the kid chips below it, so
  there are two filters. Keep both, or drop the chips when the rings show?
- The Family Board button now shows on Home on every iPhone. It's free, and it shares a name with
  the paid iPad Family Board.
- Calendar's "Today" toolbar button is now an icon (calendar.badge.clock) on every iPhone,
  instead of the word "Today".
- The chore chart's tap on a past day checks the chore off as a parent (approved, with points),
  including days earlier in the week.
