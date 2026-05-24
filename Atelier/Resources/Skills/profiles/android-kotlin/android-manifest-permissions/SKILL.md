---
name: android-manifest-permissions
description: Use when adding or modifying AndroidManifest.xml entries, permissions, or intent filters. Reference for the runtime permission flow on Android 13+.
---
# AndroidManifest + Permissions

## Where things go
- `<uses-permission>` → top of manifest, before `<application>`.
- `<uses-feature android:required="false" />` if your app degrades gracefully.
- Activities/services/receivers → inside `<application>`.

## Permission tiers
| Tier | Examples | Flow |
|---|---|---|
| Normal | INTERNET, ACCESS_NETWORK_STATE | Manifest only. Granted at install. |
| Runtime / dangerous | CAMERA, RECORD_AUDIO, ACCESS_FINE_LOCATION, READ_CONTACTS | Manifest + `ActivityResultContracts.RequestPermission` at runtime. |
| Special | SYSTEM_ALERT_WINDOW, MANAGE_EXTERNAL_STORAGE, POST_NOTIFICATIONS (≥ Android 13) | Manifest + per-permission user opt-in via Settings intent. |

## Runtime permission (Compose-friendly)
```kotlin
val launcher = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.RequestPermission()
) { granted -> ... }

LaunchedEffect(Unit) {
    if (ContextCompat.checkSelfPermission(...) != PackageManager.PERMISSION_GRANTED) {
        launcher.launch(Manifest.permission.CAMERA)
    }
}
```

## Don't
- Re-request a permission the user denied without showing a rationale first (`shouldShowRequestPermissionRationale`).
- Bundle multiple dangerous permissions in one prompt — request just-in-time, scoped.
- Forget `POST_NOTIFICATIONS` on Android 13+ — silent failure otherwise.

## When adding intent filters
- `<intent-filter android:exported="true">` required if external apps invoke you. Otherwise `exported="false"`.
- Deep links: include both `<data android:scheme="..." />` and `android:host="..."`.
- Verify with `adb shell am start -W -a android.intent.action.VIEW -d "yourscheme://path"`.

## Verify
- `./gradlew assembleDebug` exit 0.
- Manifest merge report: `app/build/outputs/logs/manifest-merger-debug-report.txt` if anything looks merged unexpectedly.
- Real device or emulator API ≥ your minSdk for runtime permission flow check.
