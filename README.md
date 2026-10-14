# Caloma

A native iPhone and iPad app for running a household: kids' chores with rewards the family
sets up itself, and the home care jobs that come around every few months. SwiftUI with Liquid
Glass, SwiftData, and the family's own iCloud as the only backend. No accounts and no servers.
Caloma is the fourth app in the family with Hearken, Sated and Suffice, and follows the same
project setup, conventions and onboarding.

The screens follow the **Tend** designs on the Claude Design canvas (iPhone and landscape
iPad): Home, the chore board, Kid View with its celebrations, Needs Your OK, New Chore,
Rewards, the kid's store, New Reward, Home Care and its task detail, and Family.

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

- **Home**: each kid's ring for today with their points (tap for the kid's page), Needs Your
  OK, the next three home care tasks, and the family goal. Toolbar: Kid View and Family.
- **Chores**: Today or This Week, filtered by kid. iPhone shows a card per kid; iPad shows a
  column per kid with Needs Your OK alongside. A parent's tap on a check approves it (or
  undoes it); tapping a chore edits it. Up-for-grabs chores ask which kid did it. This Week
  shows each chore with a dot per day.
- **Needs Your OK**: finished chores (with the kid's photo when the chore asks for one) and
  reward requests. Send Back reopens a chore for the kid; Approve All clears the list.
- **New Chore**: name and icon (a dozen quick picks, or More Icons for a searchable library of
  about 250 grouped by Cleaning, Kitchen, Pets, School, Rewards, Home Care and more), kids, Up for Grabs (open to every kid, so it clears and locks the kid picks), Take Turns (swaps each week), Once /
  Daily / Weekdays / Weekly on chosen days, points (with the allowance it's worth), Ask for a
  Photo, Needs a Parent's OK.
- **Rewards**: each kid's balance, the family goal, and the store filtered by Privileges,
  Experiences, Money or Items. Long-press the goal to mark it reached.
- **New Reward**: live preview tile, icon, kind, cost (with "about N days of chores"),
  limit (once a day, once or twice a week, once a month), who can get it, Needs a Parent's
  OK, Make It a Family Goal (one at a time).
- **Home Care**: Overdue / Next 30 days / Done this year, grouped by date or by area. Task
  detail has Mark Done (tap again to undo), Give to a Kid (becomes a one-time chore; approving
  it marks the task done), details, history and notes.
- **Family**: members (photos cropped in Move and Scale; a color for everyone, from the
  presets or any custom color), what points are called (Points, Stars, Coins or
  your own word), approvals by default, streak bonus, allowance (rate, payday, spend / save /
  give split, Pay Out Now), home care reminders, accent color, erase.
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
- The next job's button gently pulses so younger kids know what to do next.
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
  repeat rule and weekdays, start day, photo, needs OK, and `homeTaskID` when it came from
  Home Care.
- `ChoreCompletion`: chore, kid, the day it counts for, pending / approved / sent back, the
  points at the time, photo.
- `Reward`, `Redemption`: the store, and kids asking for things. Pending requests set points
  aside so they can't be spent twice.
- `PointEntry`: every change to a kid's points (chore, streak bonus, reward, family goal,
  allowance, adjustment). A balance is the sum.
- `HomeTask`, `HomeTaskLog`: what needs doing, how often, when it's next due, and each time
  it was done.

All the arithmetic (who has what on which day, turns, streaks, balances, reward limits,
allowance, due dates) is in `Models/ChoreMath.swift` on plain Sendable records, and tested in
`CalomaTests/ChoreMathTests.swift`.

Every property has a default and nothing is unique, so all eight models sync with CloudKit
as they are.

## Turning on iCloud sync

The family's data is saved on the device while `AppConfig.cloudSyncEnabled` is `false`. To
sync through the private iCloud database:

1. In **Signing & Capabilities**, confirm the iCloud container is checked under **CloudKit**.
   Push Notifications and Remote notifications are already in the entitlements and Info.plist.
2. Set `AppConfig.cloudSyncEnabled = true` and run once on a device signed in to iCloud.
3. In the CloudKit Console, deploy the development schema to production before TestFlight.

Settings (point name, allowance, accent) are in `UserDefaults` for now; they move to
`NSUbiquitousKeyValueStore` when sync goes on.

## Sharing with your partner and the kids' devices (next milestone)

Private-database sync keeps one Apple Account's iPhone, iPad and Mac in step, which already
covers a shared family iPad on the same account. Two parents on two Apple Accounts, or kids
on their own devices, need **CloudKit sharing**, the same plan as Suffice's: keep the
SwiftData models for the UI, mirror them into a shared record zone with `CKSyncEngine`, and
invite from Family with `UICloudSharingController`.

## Next up

- CloudKit sharing for the family (above).
- Widgets: today's chores for each kid, Needs Your OK, and home care due soon.
- Notifications when a kid finishes a chore or asks for a reward (needs sharing first).
- App Intents ("Mark Max's bed made"), and a Kid View Live Activity.
- Sounds to go with the celebrations.
- Missed chores costing points, and per-kid point rules.

## App icon

`Caloma/AppIcon.icon` is the Icon Composer file (from `~/Developer/app-icons/caloma.icon`): four
layered shapes on a pink-to-red gradient, with Liquid Glass translucency. Edit it in Icon Composer
and copy it back over this one.

## Project layout

```
Caloma/
  App/            App entry, router, tab bar, configuration, preview data
  DesignSystem/   Theme and colors, cards, avatars, rings, chips, photo tools
  Features/       Onboarding, Home, Chores (board, approvals, editor), Rewards (store,
                  editor), HomeCare (list, detail, editor), Family (settings, kid page,
                  member editor), KidView (Kid View, store, celebrations)
  Models/         SwiftData models, ChoreMath, FamilySnapshot, persistence and starter data
  Services/       Family (every change to points, chores, rewards and home care), reminders
CalomaTests/      Swift Testing
```

## iPad

The app runs in every orientation, in Split View and Stage Manager.

- Tabs sit in a bar at the top that opens into a sidebar (`.sidebarAdaptable`).
- Chores shows a column per kid with Needs Your OK beside it, as in the iPad designs.
- Kid View lays jobs out in a grid of large tiles, with the store beside the jar.
- Keyboard: ⌘N new chore, ⇧⌘N new reward, ⌘1–4 the tabs, ⌘O Needs Your OK, ⌘K Kid View.
