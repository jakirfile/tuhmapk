# AllApp version and update checklist

## Current configuration

- Android application ID: `com.ijtc.allapp`
- Version in `app/build.gradle.kts`: `1.0` (`versionCode` 1)
- Update package: `app-debug.apk`
- Update manifest: `update.json`, pointing to the `allapp` GitHub repository
- APK signing: the local Android debug key

## Build and install

Run `Build-Debug-Install.bat` to build, install, and launch the debug app on a
connected Android device. To build without installing, run:

```powershell
.\gradlew.bat :app:assembleDebug -PskipInstallAndRun=true --console=plain --no-configuration-cache
```

The APK is written to
`app\build\outputs\apk\debug\app-debug.apk`. The no-configuration-cache option
avoids stale output paths from an older Gradle configuration cache.

## Prepare and publish an update

1. Run `App-Update.bat` to open the version-update card form. The updater
   considers the version in Gradle, `update.json`, and any connected device
   with the configured application ID installed. The pending values start
   from Gradle (or the detected installed version name when its code is
   higher). Use `+ Name` / `- Name` to adjust the last numeric segment, or
   type any Version Name (for example `1.2-beta` or `AllApp Special`). Use
   `+ Code` / `- Code` or type any positive Version Code, including a lower
   one. `Save & Build` builds exactly the displayed values without changing
   them automatically and does not show a version-floor warning. Android may
   still reject installing an APK whose Version Code is lower than the one
   already installed; remove the installed app first in that case.
   The check icon beside either version field saves just that value to
   `app/build.gradle.kts` and updates the Current display without building an
   APK. It does not update `update.json`, `index.html`, or the APK; use
   `Save & Build` to prepare a matching installable update.
   Edit the Android package name (`applicationId`), App Name, `app_url`, and
   `update_manifest_url` directly in the form, or enter replacements in the
   empty fields below them and use the apply icons to move the values into the
   main fields. Those apply actions only update pending form values; use
   `Save & Build` to save them. Changing the application ID
   makes Android treat the APK as a separate app; it will not update the old
   app or transfer its data. The source `namespace` remains unchanged. The
   form previews the current logo and lets you select a new PNG. Clicking the
   adjacent check icon immediately saves it as
   `app/src/main/res/drawable/logo.png`, moves the preview to the current-logo
   box, and clears the new-logo box. Gradle uses `logo.png` as the launcher
   and Recent Apps logo during `Save & Build`. When no fixed `logo.png` exists,
   Gradle continues using the legacy drawable named after the final
   `applicationId` segment.
   Generated launcher
   and Recent Apps icons use 20dp of padding on each side.
   Enter a custom HTTPS URL in the QR card and choose `Refresh QR` to update
   `qr.png` without building an APK; leaving the field blank keeps the current
   saved QR target. The last generated QR target is saved in `index.html`.
   `Save & Build` later regenerates the QR for that saved target, so the
   custom link remains active. Close the form to discard pending app/version
   settings; a QR refresh is saved immediately.
2. Save to build and verify the debug APK. The updater runs Gradle without the
   configuration cache, checks the APK and its signature, updates the
   manifest's version, application ID, and SHA-256, refreshes the version and
   package name shown in `index.html`, and regenerates `qr.png`. The app requests the APK with cache bypass to
   avoid receiving an older GitHub CDN copy than the manifest.
3. Run `App-Debug-Upload.bat` separately to publish the APK and matching
   update files to `https://github.com/jakirfile/allapp`. The script reads the
   package name from the built APK metadata and synchronizes it to `update.json`
   and the page fallback before publishing. The script publishes
   the versions exactly as entered and creates a fresh publication commit even
   when the release files are identical to the last upload. The manifest points
   to an APK whose filename contains its SHA-256, so older app builds do not
   fetch a stale APK from GitHub's CDN. The stable `app-debug.apk` is also
   uploaded for the download page. The download page is
   `https://jakirfile.github.io/allapp`.
4. Confirm the published `update.json` version and SHA-256 match the APK.

Keep the application ID and signing key consistent so existing installations
can update without losing their app data. The app checks for an
update if either `versionName` or `versionCode` differs from the installed
version. Android still rejects a lower `versionCode`; use the same code for a
name-only update, or a greater code when increasing it.
