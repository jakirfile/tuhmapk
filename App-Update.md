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

1. Run `App-Update.bat` and adjust the version. The updater considers
   the version in Gradle, `update.json`, and any connected device with the
   configured application ID installed. The pending values start from Gradle;
   the Save action builds exactly the displayed Version Name and Version Code without
   changing either automatically. Use option 6 to enter any positive code,
   including a lower one. Saving a code that is not higher than the
   current/installed minimum shows a warning; Android will not install it over
   a higher version, so that installation must be removed before installing
   the lower-code APK. Without a connected device, the updater reports that it
   can only use the Gradle and manifest values.
   Use option 5 to enter a custom Version Name (for example `1.2-beta` or
   `AllApp Special`), option 6 to set a Version Code, and option 7 to change
   the Android package name (`applicationId`). Changing the application ID
   makes Android treat the APK as a separate app; it will not update the old
   app or transfer its data. The source `namespace` remains unchanged.
   After setting values, choose `S` to save and build; quitting with `Q`
   discards pending values.
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
