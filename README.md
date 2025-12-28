# Gentle Nudge

A modern iOS reminders app with Claude AI integration and Apple Reminders sync.

## Features

- **Smart Categories**: Organize reminders with customizable categories
- **AI Enhancement**: Use Claude to add context and suggest categories
- **Apple Reminders Sync**: Backup all reminders to Apple's native Reminders app
- **Modern UI**: Clean SwiftUI design with smooth animations and dark mode support

## Setup

### 1. Create Xcode Project

1. Open Xcode and create a new iOS App project
2. Select "SwiftUI" for Interface and "SwiftData" for Storage
3. Set deployment target to iOS 17.0+
4. Name it "GentleNudge"

### 2. Add Source Files

Copy all files from `GentleNudge/` folder into your Xcode project:
- Models/
- Views/
- Services/
- Utilities/

### 3. Configure Claude API

1. Get an API key from [console.anthropic.com](https://console.anthropic.com/)
2. Open `Utilities/Constants.swift`
3. Replace `YOUR_CLAUDE_API_KEY_HERE` with your actual API key

### 4. Add Info.plist Keys

Add these keys to your Info.plist for Reminders access:

```xml
<key>NSRemindersUsageDescription</key>
<string>Gentle Nudge needs access to sync your reminders to Apple's Reminders app as a backup.</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>Gentle Nudge needs full access to sync your reminders to Apple's Reminders app as a backup.</string>
```

### 5. Build and Run

Build the project (⌘B) and run on a simulator or device (⌘R).

## Project Structure

```
GentleNudge/
├── GentleNudgeApp.swift          # App entry point
├── Models/
│   ├── Reminder.swift            # Reminder data model
│   └── Category.swift            # Category data model
├── Views/
│   ├── ContentView.swift         # Main tab navigation
│   ├── TodayView.swift           # Today's reminders
│   ├── AllRemindersView.swift    # All reminders by category
│   ├── AddReminderView.swift     # Create new reminder
│   ├── ReminderDetailView.swift  # Edit reminder
│   ├── CategoriesView.swift      # Category management
│   ├── SettingsView.swift        # App settings
│   └── Components/
│       ├── ReminderRow.swift     # Reminder list item
│       ├── CategoryChip.swift    # Category tag
│       └── AIEnhanceButton.swift # AI action button
├── Services/
│   ├── ClaudeService.swift       # Claude API integration
│   ├── AppleRemindersService.swift # EventKit sync
│   └── URLMetadataService.swift  # Link preview
└── Utilities/
    ├── Constants.swift           # App configuration
    └── Extensions.swift          # Swift extensions
```

## Default Categories

- 🔴 Urgent Today
- 🟠 House
- 🟢 Work
- 🟣 Photos
- 🔵 When There's Time
- 🩷 Personal

## AI Features

- **Enhance Reminder**: Add context and details to any reminder
- **Suggest Category**: AI recommends the best category for a reminder
- **Smart Description**: Automatically understand video/link content

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Claude API key (for AI features)
