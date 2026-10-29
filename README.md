# AllApp Android app

The Android app opens `https://allapp.jakirfile.workers.dev` in a full-screen
WebView. The website provides the app experience; the Android app no longer
contains the former native screens, account flows, or local-data features.

The WebView enables JavaScript and DOM storage, keeps website navigation inside
the app, restores its current page after recreation, and uses the Android Back
button to navigate WebView history before closing the app. The app requires an
internet connection to load the site.
On the Session page, the app remembers a valid five-digit code in WebView storage
and fills it in the next time that page is opened.
The app also saves non-empty email and phone values from the Login page locally
and restores them after logout; it does not save passwords.
Invoice images are saved to Pictures/AllApp and other downloaded files to
Downloads/AllApp. Android 10 and later do not need storage permission for these
downloads; Android 9 and earlier prompt for permission when a download starts.
QR scanning requests camera access through Android when first used; the app
does not enable the camera without the user's approval.
Location-based website features request location access through Android when
first used; the app does not enable location access without the user's approval.
Print requests open Android's print interface.
External communication links, including SMS and supported social-app links,
are handed to Android so the corresponding installed app can open them.

Existing files under `Data/` are preserved but are not read by the Android app.
The standalone website, Apps Script sources, and build/publishing helpers remain
separate project assets.

## Build and test

Run the focused configuration test with:

```powershell
.\gradlew.bat testDebugUnitTest -PskipInstallAndRun=true
```

Build the debug APK without installing it with:

```powershell
.\gradlew.bat assembleDebug -PskipInstallAndRun=true
```

The debug APK is at `app\build\outputs\apk\debug\app-debug.apk`.

Install that existing APK directly with ADB, without rebuilding or launching
the app, by running:

```bat
Install-Debug.bat
```

If the app is already installed, the script installs over it with
`adb install -r -d`, preserving its local data and allowing a lower version
code when Android permits it. The APK must still use the same signing key as
the installed app. If it is not installed, the script performs a fresh install.
After either install path, it launches the app. Set `ADB_SERIAL` if more than
one device is connected.
