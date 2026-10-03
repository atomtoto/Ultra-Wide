# SwiftUI Native-First Design

When building or modifying the UI of this app, follow a **native-first SwiftUI approach**.

The goal is for the app to feel like a first-party Apple app: simple, system-consistent, adaptive, accessible, and based as much as possible on standard SwiftUI components and behaviors.

## Core rule

**Always prefer an existing native SwiftUI component or system behavior over a custom implementation.**

Before creating a custom UI component, modifier, interaction, animation, navigation system, control, or visual effect, first check whether SwiftUI already provides an appropriate native solution.

## Prefer native APIs

Prefer components and APIs such as:

- `NavigationStack`
- `NavigationSplitView`
- `List`
- `Form`
- `Section`
- `ScrollView`
- `Button`
- `Toggle`
- `Picker`
- `Menu`
- `ControlGroup`
- `TextField`
- `SecureField`
- `Slider`
- `ProgressView`
- `Label`
- `ContentUnavailableView`
- `DisclosureGroup`
- `TabView`
- `.toolbar`
- `.searchable`
- `.sheet`
- `.popover`
- `.alert`
- `.confirmationDialog`
- `.contextMenu`
- `.swipeActions`
- `.refreshable`
- `.navigationTitle`
- `.navigationDestination`

Use native presentation, navigation, gestures, scrolling behavior, transitions, keyboard handling, selection behavior, and accessibility whenever possible.

## Visual design

Prefer system-provided styling:

- semantic colors such as `.primary`, `.secondary`, `.tertiary`, etc.
- system backgrounds and materials
- native button styles
- native list and form appearances
- SF Symbols
- system typography and Dynamic Type
- standard spacing and platform conventions
- native Liquid Glass / material APIs when available

Avoid manually recreating Apple UI with rectangles, gradients, overlays, blur layers, custom shadows, or hard-coded dimensions when the system already provides the intended appearance.

**Do not interpret “Apple-like” as “recreate Apple’s visual appearance manually.”**

## Avoid unnecessary custom UI

Do **not** create custom versions of:

- navigation bars
- tab bars
- toolbars
- sheets
- alerts
- menus
- context menus
- segmented controls
- switches
- search bars
- list rows
- disclosure indicators
- swipe actions
- standard buttons

unless the native SwiftUI implementation genuinely cannot satisfy the required behavior.

Do not build a custom component merely to obtain a slightly different visual appearance.

## Custom components

Custom views are still appropriate for **app-specific content** and reusable composition.

However, custom controls or system-like UI should only be introduced when:

1. no suitable native SwiftUI API exists,
2. the product requirement cannot reasonably be achieved by composing native APIs,
3. or there is a clear functional reason for deviating from platform conventions.

When introducing such a component, keep the custom implementation as small as possible and continue using native SwiftUI primitives internally.

## UIKit / AppKit

Do not use UIKit/AppKit bridges (`UIViewRepresentable`, `UIViewControllerRepresentable`, etc.) unless SwiftUI lacks the necessary capability.

Prefer modern SwiftUI APIs even if an older UIKit solution is more familiar.

## Adaptivity

Avoid hard-coded layouts designed for one specific iPhone.

Prefer:

- intrinsic sizing
- adaptive layouts
- safe areas
- Dynamic Type
- semantic alignment
- environment values
- size classes only when genuinely necessary

The UI should naturally adapt across supported Apple devices and accessibility settings.

## Decision rule

When several implementations are possible, choose them in this order:

**Native SwiftUI API → composition of native SwiftUI components → small custom SwiftUI component → UIKit/AppKit bridge → fully custom control**

When reviewing existing code, proactively simplify custom implementations when they can now be replaced by a native SwiftUI API.

The desired result is not merely an interface that visually resembles iOS. It should **behave like iOS because it is built from the same system primitives Apple expects apps to use.**

For this project, follow this hierarchy by default: **native SwiftUI → native composition → custom only when necessary.**
