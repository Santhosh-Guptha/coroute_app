# CoRoute Project Context & Technical Guide

See root documentation: [PROJECT_CONTEXT.md](../PROJECT_CONTEXT.md)

### Quick Reference:
- **Active App Package**: `space.devmonks.coroute_app`
- **Active Firebase Project**: `corout-uat` (`87798956679`)
- **App ID**: `1:87798956679:android:3c80773227ff3cee24ee22`
- **Primary Database**: Oracle 26ai Autonomous Cloud Database SODA REST API (`coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com`)
- **Gateway VM**: `152.67.181.198`
- **Master Admin**: `santhoshbukka5@gmail.com`
- **Web OAuth Client ID**: `87798956679-ivggpbpote5cf2cvi8mtg8gja3r1sfve.apps.googleusercontent.com`
- **Current Version**: `2.0.0 (Build 46)` / `1.0.0+46`
- **Build Command**: `flutter build apk --release`
- **Distribution Command**:
  ```powershell
  firebase appdistribution:distribute "build\app\outputs\flutter-apk\app-release.apk" --app "1:87798956679:android:3c80773227ff3cee24ee22" --project "corout-uat" --testers "santhoshbukka5@gmail.com"
  ```
