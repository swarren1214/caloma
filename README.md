# Caloma

A native iPhone and iPad app for running a household: kids' chores with rewards the family
sets up itself, a family calendar, and the home care jobs that come around every few months.
SwiftUI with Liquid Glass, SwiftData, and the family's own iCloud as the only backend, shared
between both parents' Apple Accounts. No accounts and no servers.
Caloma is the fourth app in the family with Hearken, Sated and Suffice, and follows the same
project setup, conventions and onboarding.

The screens follow the **Tend** designs on the Claude Design canvas (iPhone and landscape
iPad): Home, the chore board, Kid View with its celebrations, Needs Your OK, New Chore,
Rewards, the kid's store, New Reward, Home Care and its task detail, Family, and the Family
Calendar row (week and month, New Event, Kid View › My Day, and the iPad week).

Requires Xcode 26 and iOS 26. iPhone and iPad.

## First run

1. Open `Caloma.xcodeproj`.
2. Select the **Caloma** target › **Signing & Capabilities** and confirm your **Team** (the
   same team as Suffice). Automatic signing registers Sign in with Apple and iCloud the first
   time you build.
3. If `com.stephenwarren.caloma` isn't available to your team, change the **Bundle
   Identifier**, then update the iCloud container in `Caloma.entitlements` and
   `AppConfig.cloudKitContainerID` to match.
4. Run. Onboarding is Welcome (Sign in with Apple, optional) → Who's in the family → Pick a
   few chores. Previews load the family from the designs (`App/PreviewSupport.swift`):
   Ella, Max and June with today part done.

The first launch adds eight home care tasks (HVAC filter, smoke detectors, dryer vent,
gutters, water heater, fridge filter, fire extinguisher, furnace) spread over the next four
months. Onboarding offers eight starter chores and the family store from the designs.

## Screens

- **Home**: each kid's ring for today with their points (tap for the kid's page), Coming Up
  (what's left on the calendar today and tomorrow), Needs Your OK, the next three home care
  tasks, and the family goal. Toolbar: Kid View and Family.
- **Chores**: Today or This Week, filtered by person. Parents can have chores too (they show
  on the board after the kids, without points). Higher-priority chores come first and
  show !, !! or !!! like Reminders. iPhone shows a card per kid; iPad shows a
  column per kid with Needs Your OK alongside. A parent's tap on a check approves it (or
  undoes it); tapping a chore edits it. Up-for-grabs chores ask which kid did it. This Week
  shows each chore with a dot per day.
- **Calendar**: Week (a week strip with a dot for each person busy that day, then the day:
  all-day things, events by time, and the day's chores) or Month (dots per person). Filter to
  one person's calendar; Chores and Home Care can each be hidden. A countdown card shows the next
  event someone's counting down to. Events show who's going (faces), who's driving and what
  to bring. iPad: the family down the side, each person's photo in a ring of their color (tap
  to hide or show them), beside a week grid of hours with a line for now, or the month and
  day side by side. To reschedule, touch and hold an event and drag it: on the iPad week grid
  to another day and time (snapping to the quarter hour, with the new time shown as you
  drag), and anywhere else onto a day in the week strip, the month or the all-day row (it
  keeps its time). A repeating event asks whether to move only that day or all of them.
- **New Event**: name (with a dot in the color it shows in), location, who's going (Everyone or anyone in the family), who's
  driving, all day or times, repeat (never, daily, weekly on chosen days, monthly, yearly,
  with an optional last day), an alert, notes. For the kids going: Remember to Bring (they
  tick it off in Kid View), Show in Kid View, Count Down to It, and a Get-Ready Chore
  ("Get ready for soccer practice" the night before, for one-time, daily and weekly events).
  Opening an event shows who's packed what, and repeating events can skip one day.
- **Needs Your OK**: finished chores (with the kid's photo when the chore asks for one) and
  reward requests. Send Back reopens a chore for the kid; Approve All clears the list.
- **New Chore**: name and icon (a dozen quick picks, or More Icons for a searchable library of
  about 250 grouped by Cleaning, Kitchen, Pets, School, Rewards, Home Care and more), kids, Up for Grabs (open to every kid, so it clears and locks the kid picks), Take Turns (swaps each week), Once /
  Daily / Weekdays / Weekly on chosen days, an optional priority (Low / Medium / High), points (with the allowance it's worth), Ask for a
  Photo, Needs a Parent's OK.
- **Rewards**: each kid's balance, the family goal, and the store filtered by Privileges,
  Experiences, Money or Items. Long-press the goal to mark it reached.
- **New Reward**: live preview tile, icon, kind, cost (with "about N days of chores"),
  limit (once a day, once or twice a week, once a month), who can get it, Needs a Parent's
  OK, Make It a Family Goal (one at a time).
- **Home Care**: Overdue / Next 30 days / Done this year, grouped by date or by area. Task
  detail has Mark Done (tap again to undo), Give to a Kid (becomes a one-time chore; approving
  it marks the task done), details, history and notes.
- **Rooms** (Family › Rooms): optional rooms with a name and icon (Add Common Rooms adds
  Kitchen, Living Room, Dining Room, Bathroom, Laundry Room, Garage, Yard and Playroom). A chore
  can be in one room, picked in New Chore (with New Room right there). The room shows on chore
  rows and as a capsule on Kid View tiles, and the Chores board has a room filter next to
  Today / This Week.
- **Family**: members (photos cropped in Move and Scale; a color for everyone, parents
  included, from the presets or any custom color; parents start teal and pink), Family
  Sharing, rooms, what points are called (Points, Stars, Coins or your own word), approvals
  by default, streak bonus, allowance (rate, payday, spend / save / give split, Pay Out Now),
  home care reminders, Apple Calendar, erase.
- **Kid page** (from Home or Rewards): balance, waiting points, streak, this week, today's
  chores, every change to their points, Adjust, and Open Kid View for them.

### Kid View

Full screen, in the kid's color, with big rounded type and big buttons. Kid View reopens if
the app was closed in it, so it's safe on a shared iPad.

- **Choosing the kid**: the Kid View button on Home and Chores is a menu with each kid, plus
  Let the Kids Pick (opens on "Who's doing chores?"). A kid's page has Open Kid View for them.
  Inside Kid View, every kid is a Liquid Glass pill (photo and first name) in a scrolling
  row across the top; the one showing is tinted in their color. Tap another to switch.
- **Leaving**: the Parent button at the top right asks for the device's Face ID or passcode,
  and nothing else. On a device with no passcode (and in the Simulator), it asks a grown-up
  multiplication question instead.

- Tapping **I did it!** bursts confetti from the card, rings out a pulse, wiggles the icon,
  floats "+15" up, and flies stars in an arc to the star counter, which bounces when they
  land. A success haptic plays.
- A progress track at the top moves the kid's avatar from stop to stop toward a trophy.
- The next job's button gently pulses so younger kids know what to do next. High-priority
  jobs come first with a red **Do this first** tag; medium ones say **Important**.
- Chores that ask for a photo open the camera (the photo library in the Simulator).
- Finishing the last job brings up the party: confetti over everything, a trophy on slowly
  turning rays, "You did it!".
- **The store**: a jar fills (with a moving surface and twinkling stars) toward the reward
  the kid is saving for. **Change** on the jar opens "What are you saving for?" to swap it, and
  when they have enough the jar shows **Get it!**. Rewards they can afford have a bouncing **Get it!**; the rest show how
  many more they need. Getting one opens a gift box that wiggles until they confirm, then
  the lid pops off with sparkles and the counter drops. Kids can **Chip In** to the family
  goal.
- With Reduce Motion on, the confetti, flying stars and bouncing are skipped; everything
  else works the same.

- **My Day** (next to My Jobs at the top of Kid View): a big "3 sleeps until Movie Night!"
  countdown with floating moons, today as a timeline (the next event is outlined and pulsing,
  with its packing list to tick off), how many jobs are left, and the rest of the week.

### Where the build goes beyond the designs

- The kid's page, Adjust points, Pay Out, the kid switcher, the parent check and the "Who's
  doing chores?" picker weren't in the designs.
- The designs' separate **+** button in the tab bar became a **+** in each tab's toolbar, which
  is what the system Liquid Glass tab bar supports.
- "This Month" on Home Care is "Next 30 days", so it doesn't empty out at the end of a month.
- Missed chores costing points isn't built; the toggle from the designs is left out until it is.

## Data model

Points are whole numbers in a ledger, so balances never drift. Records link by UUID
(`choreID`, `memberID`, `rewardID`, `taskID`) rather than SwiftData relationships, so deleting
a chore or a reward never deletes anyone's history.

- `Member`: name, parent or kid, color (a preset name or "#RRGGBB"), photo (a 600 px square
  JPEG, `@Attribute(.externalStorage)`).
- `Chore`: title, icon, points, kids (comma-separated UUIDs), take turns, up for grabs,
  repeat rule and weekdays, start day, priority (`priorityRaw`, 0 is none), photo, needs OK, and `homeTaskID` when it came from
  Home Care.
- `ChoreCompletion`: chore, kid, the day it counts for, pending / approved / sent back, the
  points at the time, photo.
- `Reward`, `Redemption`: the store, and kids asking for things. Pending requests set points
  aside so they can't be spent twice.
- `PointEntry`: every change to a kid's points (chore, streak bonus, reward, family goal,
  allowance, adjustment). A balance is the sum.
- `Room`: name, icon, order. `Chore.roomID` links a chore to one.
- `FamilyEvent`: title, icon, location, notes, start and end, all day, who's going
  (comma-separated UUIDs, empty for everyone), driver, repeat rule, weekdays, last day, skipped
  days, alert, what to bring, Kid View, countdown, and `getReadyChoreID` (that chore has
  `eventID` back).
- `EventPacking`: which "bring" items a kid has packed for one day of an event.
- `FamilySetting`: one family-wide setting (points name, approvals, allowance, accent, family
  name), so both parents' phones agree. Its id is made from its key.
- `HomeTask`, `HomeTaskLog`: what needs doing, how often, when it's next due, and each time
  it was done.

All the arithmetic (who has what on which day, turns, streaks, balances, reward limits,
allowance, due dates) is in `Models/ChoreMath.swift`, and the calendar's (repeats, multi-day
events, countdowns, month grids) in `Models/CalendarMath.swift`, on plain Sendable records,
tested in `CalomaTests/ChoreMathTests.swift` and `CalendarMathTests.swift`.

Every property has a default and nothing is unique (CloudKit's rules), and every model's
`id` keeps its value after deletion (`.preserveValueOnDeletion`) so deletes can be synced.

## iCloud sync and Family Sharing

Sync is on (`AppConfig.cloudSyncEnabled`). Everything is saved on the device with SwiftData,
and `Sync/CloudSync.swift` keeps it in step through CloudKit with a `CKSyncEngine`:

- The family lives in one record zone, **Family**, in the private database of the parent who
  set it up. Every model is a record named by its UUID (`Sync/CloudRecord.swift` has each
  model's fields; add new properties there too).
- Local changes come from SwiftData's history. A save queues what changed; deletes are read
  from the history's tombstones. Changes from iCloud are saved by a context whose author is
  `sync`, so they aren't sent back.
- When two phones change the same record, the last one sent wins (it takes the server's change
  tag and sends again).
- **Family Sharing** (Family › Family Sharing) shares the whole zone with
  `UICloudSharingController`: invite in Messages or Mail. The other parent taps the invitation,
  Caloma asks "Join the family?" (`JoinFamilySheet`), and their phone switches to the family's
  zone in its shared database. What was on their phone is replaced. Leave Family takes it back
  off their phone; the owner can stop sharing from the same sheet.
- Family-wide settings sync as `FamilySetting` records (`Sync/SharedSettings.swift`); device
  settings (reminders, Kid View, Apple Calendar) stay on each device.
- Erase All Data deletes the zone from iCloud too (for everyone), or for someone who joined,
  leaves the family.

Before the first run with sync:

1. In **Signing & Capabilities**, confirm iCloud › **CloudKit** is checked with
   `iCloud.com.stephenwarren.caloma`, and Push Notifications and Background Modes › Remote
   notifications are on (they're already in the entitlements and Info.plist, along with
   `CKSharingSupported`).
2. Run on a device signed in to iCloud. Record types are created in the development
   environment the first time each kind of record is saved.
3. Test sharing with two Apple Accounts (two devices, or a device and a second account on
   another device). Development builds share in the development environment.
4. Before TestFlight, the record types have to be in **Production**. TestFlight and App Store
   builds use Production, where records can't create new types, and the types only appear in
   Development when a build run from Xcode saves them. `CloudKit/schema.ckdb` lists every
   type and field, so there's no need to wait for that. In the CloudKit Console, with
   **Development** selected, choose **Import Schema…** and pick `CloudKit/schema.ckdb`, then
   **Deploy Schema Changes…**. (Apple's built-in SwiftData sync creates types by itself;
   Caloma syncs on its own so two Apple Accounts can share a family, so it needs this file.)

   The file includes CloudKit's own `cloudkit.share` type (copied from a Development
   export), since an import that leaves it out is refused as an attempt to delete it. If the
   import ever fails, choose **Export Schema** in Development and compare.

   Adding a synced field or model means adding it to `CloudRecord.swift` *and* to
   `schema.ckdb`, importing and deploying again before the TestFlight build goes out. If
   iCloud refuses records, Family › Family Sharing says so, and the device sends everything
   again on its next launch.

   A second device on the same Apple Account (or a reinstall) finds the family on the welcome
   screen and asks "Who's using this iPad?" instead of setting up again.

### "Needs your OK" notifications

When a kid finishes a chore that needs approval, or asks for a reward, each parent's phone
shows a notification: "Max finished a chore · Clean the bathroom sink · +15 stars", with the
photo if there is one. Touch and hold it for **Approve** and **Send Back** (or **Decline** for
a reward); both ask for Face ID, so a kid can't approve from the lock screen. Tapping it opens
Needs Your OK. When one parent handles it, the other parent's notification goes away.

There's no server: CloudKit's silent push wakes the phone, sync fetches the new request, and
the phone posts the notification itself (`ApprovalAlerts`). iOS decides when to deliver
background pushes, so they can lag by a few minutes, and a phone where Caloma was swiped
away in the app switcher won't get them until it's opened. Devices in Kid View don't show
them. Family › Reminders › Needs Your OK turns them off per phone.

## Apple Watch (parents)

A Watch app for parents, from the Tend designs. Turn the crown between four pages:

- **Needs Your OK**: the oldest request, with the kid's photo, **Approve · +15** and **Send
  Back** (or **Decline** for a reward), then a check and the next one.
- **Coming Up**: the next event counting down ("Starts in 25 min"), with **You're driving**
  when it's you, **Directions** in Maps and a **5m** nudge; the rest of today and tomorrow
  below, then tonight's dinner when BigTable has one planned.
- **Kids Today**: a ring per kid filling as their jobs get done, and how many need your OK.
- **Home Care**: what's late or due in the next few days, each with **Mark Done**.

Smart Stack widgets and complications: **Coming Up** (rectangular, circular, inline, corner),
**Kids Today** (rectangular, circular, inline) and **Home Care** (rectangular, inline). Coming
Up rises in the Smart Stack in the hour before an event, highest when you're driving, and Kids
Today when something needs your OK.

The iPhone does the work (`Services/WatchBridge.swift`): whenever the family changes it sends a
small `WatchSnapshot` (`Shared/WatchSnapshot.swift`) to the watch, and the watch's taps come
back as `WatchAction`s, waking Caloma on the iPhone in the background if needed. The watch keeps
the last snapshot, so it still shows something when the phone is out of reach, and queues taps
until it's back. The "Needs your OK" notifications from the phone show on the watch too, and
their Approve / Send Back buttons work there (the Watch app answers them through the phone). "You're driving" uses the parent set up on that iPhone.

### Watch targets

The Watch app is the **CalomaWatch Watch App** target (`CalomaWatch Watch App/`), embedded in
the iPhone app, with the widgets in **CalomaWatchWidgetsExtension** (`CalomaWatchWidgets/`),
embedded in the Watch app. Building Caloma builds and installs all three.

- `Caloma/Shared/WatchSnapshot.swift` is a member of all three targets.
- Both watch targets have the App Group `group.com.stephenwarren.caloma`, which is how the
  widgets read what the app received.
- The watch app uses the same `AppIcon.icon` as the iPhone app (a copy in its folder).
- Keep the watch targets' Version (`MARKETING_VERSION`) the same as the iPhone app's, or App
  Store Connect rejects the upload.

Kids' watches (the ring, timer, packing list and watch face designs) and Siri come next. Kids'
watches set up with Family Setup have no iPhone of their own, so they'll sync through iCloud.

## Widgets, CarPlay and Siri

From the CarPlay designs on the canvas. On iOS 26 the iPhone's widgets and Live Activities also
show on the CarPlay dashboard, so none of this needs a CarPlay app (which Apple only allows for
navigation, audio, messaging and a few other kinds of app).

- **Widgets** (`CalomaWidgets/`): **Coming Up** (who's going, who's driving), **Kids Today**
  (rings, and what needs your OK) and **Home Care** (late or due soon, with what to buy). They
  read the same `WatchSnapshot` the watch gets, saved to the app group by `WatchBridge`
  whenever the family changes. Coming Up also shows tonight's dinner from BigTable (beside
  the header on medium; under a lone event on small). It's `WatchSnapshot.dinner`, filled from
  `HearthLink` (`Services/Hearth/`), and a new BigTable plan refreshes the snapshot; the widgets
  don't need the Hearth app group.
- **"You're driving" Live Activity** (`DrivingLiveActivity`, `Shared/DrivingActivity.swift`):
  for the next event you're the driver of, from two hours before. Countdown, the bring list
  with what's packed (it updates as the kids tick things off in Kid View) and Directions. Lock
  Screen, Dynamic Island, CarPlay and Apple Watch. A Live Activity can only start while Caloma
  is open or from an intent, so: open Caloma, or say "Start driving in Caloma", or set up a
  Shortcuts automation **When CarPlay connects → Start Driving** to have it appear in the car.
- **Siri** (`Services/CalomaIntents.swift`): "Check what needs my OK in Caloma" (reads the oldest
  request and asks "Approve it?"), "What's coming up in Caloma", "Start driving in Caloma".

### Adding the widget extension in Xcode (once)

1. **File › New › Target… › iOS › Widget Extension**. Product Name `CalomaWidgets`. Untick
   Include Live Activity, Include Control and Include Configuration App Intent. Embed in
   **Caloma**.
2. Xcode makes a `CalomaWidgets` folder, where `CalomaWidgets.swift` already is: delete only
   Xcode's generated `.swift` files (keep `CalomaWidgets.swift`, `Assets.xcassets`,
   `Info.plist`).
3. Select `Caloma/Shared/WatchSnapshot.swift` and `Caloma/Shared/DrivingActivity.swift`; under
   Target Membership tick **CalomaWidgetsExtension**. (Nothing else from `Caloma/`.)
4. **CalomaWidgetsExtension › Signing & Capabilities › + Capability › App Groups**, tick
   `group.com.stephenwarren.caloma`. The Caloma app already lists it in its entitlements;
   if its Signing & Capabilities shows App Groups unticked, tick it there too.
5. Deployment target iOS 26, Version the same as the app's (0.1).

## Other Hearth apps

Caloma shares with Steve's other apps on the same device through the app group
`group.com.stephenwarren.hearth` (`Services/Hearth/`; `HearthShared.swift` is synced from
`~/Developer/hearthkit`, don't edit it here).

- **The family**: `HearthLink.publishFamily(in:)` (after every save, via `WatchBridge`) shares
  names, roles, colors, who this device belongs to (`me`), and each person's photo as a 512 px
  JPEG in the shared photos folder. Photos are only re-encoded when they change (a size + hash
  fingerprint per member), and photos of people who've gone are deleted.
- **Photos from the other apps**: anyone without a photo in Caloma shows the one another Hearth
  app has for the same name (`HearthPhotos`, read once per name and refreshed when another app
  shares something). Your own photo in Caloma always wins.
- **One Sign in with Apple**: after signing in, the Apple user ID and name go to
  `HearthAccounts.saveAppleID` (Apple only gives the name to the first app that asks). When
  Hearken or another Hearth app already signed in, Welcome shows **Continue as <name>**
  instead of the Apple button, once Apple confirms the sign-in is still good.
- **Tonight's dinner** from BigTable on Home, the calendar, the widgets and the watch.

## Apple Calendar

Off by default; Family › Calendar › Apple Calendar turns on either or both, per device:

- **Show Apple Calendar Events**: the calendars picked there show on the family calendar,
  read-only, with their calendar's color and name.
- **Add Family Events to Apple Calendar**: the next two months of family events are written
  to a calendar named Caloma, and rewritten whenever an event changes. Turning it off takes
  them back out.

## Next up

- Choose who you are on each phone (for "Mom drives" alerts only on Mom's phone).
- Widgets: today's chores for each kid, Needs Your OK, and home care due soon.
- Notifications when a kid finishes a chore or asks for a reward, now that sharing is in.
- App Intents ("Mark Max's bed made"), and a Kid View Live Activity.
- Sounds to go with the celebrations.
- Missed chores costing points, and per-kid point rules.

## App icon

`Caloma/AppIcon.icon` is the Icon Composer file (from `~/Developer/app-icons/caloma.icon`): four
layered shapes on a pink-to-red gradient, with Liquid Glass translucency. Edit it in Icon Composer
and copy it back over this one.

The welcome screen shows the icon from Icon Composer's light and dark PNG exports
(`CalomaMark` in the asset catalog, from `caloma-default-1x.png` and `caloma-dark-1x.png`);
re-export and replace them when the icon changes. The default accent, rose `#E0284F`, comes
from the icon's gradient, deepened so white text on it stays readable.

## Project layout

```
Caloma/
  App/            App entry, router, tab bar, configuration, preview data
  DesignSystem/   Theme and colors, cards, avatars, rings, chips, photo tools
  Features/       Onboarding, Home, Chores (board, approvals, editor), Calendar (week, month,
                  iPad grid, event editor and detail, Apple Calendar settings), Rewards
                  (store, editor), HomeCare (list, detail, editor), Family (settings, kid
                  page, member editor, rooms, sharing), KidView (Kid View, My Day, store,
                  celebrations)
  Models/         SwiftData models, ChoreMath, CalendarMath, FamilySnapshot, persistence and
                  starter data
  Services/       Family (every change to points, chores, rewards, events and home care),
                  reminders, event alerts, Apple Calendar
  Sync/           CloudKit sync engine, record mapping, sharing, shared settings
CalomaTests/      Swift Testing
```

## iPad

The app runs in every orientation, in Split View and Stage Manager.

- Tabs sit in a bar at the top that opens into a sidebar (`.sidebarAdaptable`).
- Chores shows a column per kid with Needs Your OK beside it, as in the iPad designs.
- Kid View lays jobs out in a grid of large tiles, with the store beside the jar.
- Calendar shows the family down the side and a week of hours, as in the iPad design.
- Keyboard: ⌘N new chore, ⇧⌘N new reward, ⌘E new event, ⌘1–5 the tabs, ⌘O Needs Your OK,
  ⌘K Kid View.
