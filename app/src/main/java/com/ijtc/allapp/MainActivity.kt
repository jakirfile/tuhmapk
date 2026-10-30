package com.ijtc.allapp

import android.accounts.AccountManager
import android.app.ActivityManager
import android.app.AlertDialog
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.view.Gravity
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.provider.Settings
import android.widget.Toast
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telephony.SubscriptionManager
import android.os.Environment
import android.print.PrintManager
import android.provider.MediaStore
import android.util.Base64
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.GeolocationPermissions
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.PermissionRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.provider.ContactsContract
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var offlineView: LinearLayout
    private var mainFrameFailed = false
    @Volatile private var loginPageActive = false
    private var failedUrl: String? = null
    private val allowedHost by lazy { Uri.parse(getString(R.string.app_url)).host }
    private var pendingRequestId: String? = null
    private var pendingFields: Set<String> = emptySet()
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private val popupDialogs = mutableSetOf<Dialog>()
    private var pendingStorageAction: (() -> Unit)? = null
    private var pendingWebPermissionRequest: PermissionRequest? = null
    private var pendingGeolocationOrigin: String? = null
    private var pendingGeolocationCallback: GeolocationPermissions.Callback? = null

    private companion object {
        const val CONTACT_PERMISSION_REQUEST = 1
        const val CONTACT_PICKER_REQUEST = 2
        const val EMAIL_ACCOUNT_PICKER_REQUEST = 3
        const val SIM_PERMISSION_REQUEST = 4
        const val FILE_CHOOSER_REQUEST = 5
        const val STORAGE_PERMISSION_REQUEST = 6
        const val WEB_CAMERA_PERMISSION_REQUEST = 7
        const val WEB_LOCATION_PERMISSION_REQUEST = 8
        const val CONTACT_BRIDGE_NAME = "MqimContactPicker"
        const val ACTION_INSTALL_STATUS = "com.ijtc.allapp.INSTALL_STATUS"
        const val RESUME_PREFS = "allapp_resume"
        const val RESUME_URL_KEY = "url"
        const val RESUME_FROM_CODE_KEY = "from_version_code"
        const val RESUME_FROM_NAME_KEY = "from_version_name"
        const val LOGIN_HISTORY_PREFS = "allapp_login_history"
        const val LOGIN_EMAIL_KEY = "email"
        const val LOGIN_PHONE_KEY = "phone"
        const val PRINT_BRIDGE_NAME = "MqimPrint"
        const val DOWNLOAD_BRIDGE_NAME = "MqimImageDownload"
        const val WEB_DOWNLOAD_SCRIPT = """
            (() => {
              if (window.__allappWebFeaturesInstalled) return;
              window.__allappWebFeaturesInstalled = true;
              window.print = () => window.MqimPrint.print();
              document.addEventListener('click', event => {
                const link = event.target instanceof Element
                  ? event.target.closest('a[download]') : null;
                if (!link || !/^(blob:|data:)/i.test(link.href)) return;
                event.preventDefault();
                fetch(link.href)
                  .then(response => response.blob())
                  .then(blob => new Promise((resolve, reject) => {
                    const reader = new FileReader();
                    reader.onload = () => resolve(reader.result);
                    reader.onerror = () => reject(reader.error);
                    reader.readAsDataURL(blob);
                  }))
                  .then(dataUrl => window.MqimImageDownload.saveFile(
                    String(dataUrl), link.download || 'AllApp-download'
                  ))
                  .catch(error => {
                    console.error('Could not download file.', error);
                    window.MqimImageDownload.reportFailure();
                  });
              }, true);
              const originalOpen = window.open.bind(window);
              window.open = (url, ...args) => {
                if (typeof url === 'string' && /^(blob:|data:)/i.test(url)) {
                  fetch(url)
                    .then(response => response.blob())
                    .then(blob => new Promise((resolve, reject) => {
                      const reader = new FileReader();
                      reader.onload = () => resolve(reader.result);
                      reader.onerror = () => reject(reader.error);
                      reader.readAsDataURL(blob);
                    }))
                    .then(dataUrl => window.MqimImageDownload.saveFile(
                      String(dataUrl), 'AllApp-download'
                    ))
                    .catch(error => {
                      console.error('Could not download file.', error);
                      window.MqimImageDownload.reportFailure();
                    });
                  return null;
                }
                return originalOpen(url, ...args);
              };
            })();
        """
        const val LOGIN_HISTORY_AUTOFILL = """
            (() => {
              if (window.__allappLoginHistoryInstalled) return;
              window.__allappLoginHistoryInstalled = true;
              const bridge = window.MqimLoginHistory;
              if (!bridge) return;

              const fieldText = (input) => [
                input.id,
                input.name,
                input.type,
                input.placeholder,
                input.getAttribute('aria-label'),
                input.labels ? Array.from(input.labels, label => label.textContent).join(' ') : ''
              ].join(' ').toLowerCase();
              const findFields = () => {
                const inputs = Array.from(document.querySelectorAll('input:not([type="password"])'));
                return {
                  email: inputs.find(input => /email|ইমেইল/.test(fieldText(input))),
                  phone: inputs.find(input => /mobile|phone|tel|number|নাম্বার|নম্বর|মোবাইল|ফোন/.test(fieldText(input)))
                };
              };
              const restore = () => {
                const fields = findFields();
                if (!fields.email && !fields.phone) return;
                try {
                  const saved = JSON.parse(bridge.read());
                  for (const key of ['email', 'phone']) {
                    const input = fields[key];
                    if (input && !input.value && typeof saved[key] === 'string' && saved[key]) {
                      input.value = saved[key];
                      input.dispatchEvent(new Event('input', { bubbles: true }));
                      input.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                  }
                } catch (error) {
                  console.error('Could not restore login history.', error);
                }
              };
              const save = () => {
                const fields = findFields();
                try {
                  bridge.save(fields.email?.value || '', fields.phone?.value || '');
                } catch (error) {
                  console.error('Could not save login history.', error);
                }
              };

              restore();
              document.addEventListener('input', event => {
                if (event.target instanceof HTMLInputElement) save();
              }, true);
              document.addEventListener('change', event => {
                if (event.target instanceof HTMLInputElement) save();
              }, true);
              document.addEventListener('submit', save, true);
              new MutationObserver(restore).observe(document.documentElement, {
                childList: true,
                subtree: true
              });
            })();
        """
        const val SESSION_CODE_AUTOFILL = """
            (() => {
              const input = document.getElementById('access-code');
              if (!input || input.dataset.allappAutofillInstalled === 'true') return;
              input.dataset.allappAutofillInstalled = 'true';
              const key = 'allapp_session_code';
              try {
                const saved = localStorage.getItem(key);
                if (/^[0-9]{5}$/.test(saved) && !input.value) {
                  input.value = saved;
                  input.dispatchEvent(new Event('input', { bubbles: true }));
                }
                input.addEventListener('input', () => {
                  if (/^[0-9]{5}$/.test(input.value)) {
                    localStorage.setItem(key, input.value);
                  }
                });
              } catch (error) {
                console.error('Could not remember the session code.', error);
              }
            })();
        """
        const val CONTACT_PICKER_POLYFILL = """
            (() => {
              let nextId = 0;
              const pending = new Map();
              window.__allappContactPickerResolve = (id, result) => {
                const callbacks = pending.get(id);
                if (!callbacks) return;
                pending.delete(id);
                try { callbacks.resolve(JSON.parse(result)); }
                catch (error) { callbacks.reject(error); }
              };
              window.__allappContactPickerReject = (id, message) => {
                const callbacks = pending.get(id);
                if (!callbacks) return;
                pending.delete(id);
                callbacks.reject(new DOMException(message, 'NotAllowedError'));
              };
              const contacts = {
                select(fields) {
                  if (!Array.isArray(fields) || fields.length === 0) {
                    return Promise.reject(new TypeError('At least one contact field is required.'));
                  }
                  const id = ++nextId;
                  return new Promise((resolve, reject) => {
                    pending.set(id, { resolve, reject });
                    window.MqimContactPicker.pick(String(id), JSON.stringify(fields));
                  });
                }
              };
              try {
                Object.defineProperty(navigator, 'contacts', {
                  configurable: true,
                  value: contacts
                });
              } catch (error) {
                console.error('Could not enable the native contact picker.', error);
              }
            })();
        """
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyRecentsIcon()

        webView = WebView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.setGeolocationEnabled(true)
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            addJavascriptInterface(ContactPickerBridge(), CONTACT_BRIDGE_NAME)
            addJavascriptInterface(LoginHistoryBridge(), "MqimLoginHistory")
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(true)
            addJavascriptInterface(PrintBridge(this), PRINT_BRIDGE_NAME)
            addJavascriptInterface(ImageDownloadBridge(this), DOWNLOAD_BRIDGE_NAME)
            webChromeClient = createWebChromeClient(this)
            setDownloadListener(createDownloadListener())
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest
                ): Boolean {
                    if (!request.isForMainFrame) return false
                    return openExternalApp(request.url)
                }

                override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                    super.onPageStarted(view, url, favicon)
                    mainFrameFailed = false
                    val uri = Uri.parse(url)
                    if (pendingWebPermissionRequest?.origin?.host != uri.host) {
                        pendingWebPermissionRequest?.deny()
                        pendingWebPermissionRequest = null
                    }
                    loginPageActive = uri.host == allowedHost &&
                        uri.path.equals("/Login", ignoreCase = true)
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: WebResourceError
                ) {
                    super.onReceivedError(view, request, error)
                    if (!request.isForMainFrame) return
                    // No internet / DNS / timeout etc.: hide Chrome's default error page
                    mainFrameFailed = true
                    failedUrl = request.url.toString()
                    view.stopLoading()
                    showOffline(true)
                }

                override fun onPageFinished(view: WebView, url: String) {
                    super.onPageFinished(view, url)
                    if (!mainFrameFailed) showOffline(false)
                    if (Uri.parse(url).host == allowedHost) {
                        view.evaluateJavascript(WEB_DOWNLOAD_SCRIPT, null)
                        view.evaluateJavascript(CONTACT_PICKER_POLYFILL, null)
                        if (Uri.parse(url).path == "/Session") {
                            view.evaluateJavascript(SESSION_CODE_AUTOFILL, null)
                        }
                        if (Uri.parse(url).path.equals("/Login", ignoreCase = true)) {
                            view.evaluateJavascript(LOGIN_HISTORY_AUTOFILL, null)
                        }
                    }
                }
            }
        }
        setContentView(
            FrameLayout(this).apply {
                // Black strip behind the status bar / navigation bar so battery, network and time stay clearly visible
                setBackgroundColor(Color.BLACK)
                addView(webView)
                offlineView = buildOfflineView()
                addView(offlineView)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
                    // Android 15+ draws apps edge-to-edge: keep the WebView out of the system bar areas
                    setOnApplyWindowInsetsListener { view, insets ->
                        val bars = insets.getInsets(
                            WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                        )
                        val ime = insets.getInsets(WindowInsets.Type.ime())
                        view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
                        WindowInsets.CONSUMED
                    }
                }
            }
        )

        val restoredPage = savedInstanceState?.let(webView::restoreState)
        if (restoredPage == null) {
            // After a self-update the app restarts fresh: reopen the page the user was on
            webView.loadUrl(consumeResumeUrl() ?: getString(R.string.app_url))
        }
        checkForUpdate()
    }

    private fun openExternalApp(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme == "http" || scheme == "https") {
            if (uri.host == allowedHost) return false
        } else if (scheme == "about") {
            return false
        }

        if (scheme == "intent") {
            val parsedIntent = try {
                Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
            } catch (_: Exception) {
                Toast.makeText(this, "এই লিংকটি খোলা যাচ্ছে না।", Toast.LENGTH_SHORT).show()
                return true
            }
            val deepLink = parsedIntent.data ?: parsedIntent.getStringExtra("browser_fallback_url")
                ?.let(Uri::parse)
            if (deepLink == null) {
                Toast.makeText(this, "এই লিংকটি খোলা যাচ্ছে না।", Toast.LENGTH_SHORT).show()
                return true
            }
            return openExternalApp(deepLink)
        }

        val action = when (scheme) {
            "sms", "smsto", "mms", "mmsto" -> Intent.ACTION_SENDTO
            else -> Intent.ACTION_VIEW
        }
        val appPackage = when (uri.host?.lowercase()) {
            "wa.me", "api.whatsapp.com", "web.whatsapp.com" -> "com.whatsapp"
            "m.me", "messenger.com" -> "com.facebook.orca"
            "facebook.com", "www.facebook.com" -> "com.facebook.katana"
            "imo.im", "www.imo.im" -> "com.imo.android.imoim"
            else -> null
        }
        if (appPackage != null) {
            try {
                startActivity(Intent(action, uri).setPackage(appPackage))
                return true
            } catch (_: ActivityNotFoundException) {
                // Fall back to the system's normal URL handler when the app is absent.
            }
        }

        return try {
            startActivity(Intent(action, uri))
            true
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "এই লিংক খোলার উপযুক্ত অ্যাপ পাওয়া যায়নি।", Toast.LENGTH_SHORT).show()
            true
        }
    }

    private fun createWebChromeClient(target: WebView) = object : WebChromeClient() {
        override fun onShowFileChooser(
            view: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: FileChooserParams
        ): Boolean {
            if (target !== webView) {
                filePathCallback.onReceiveValue(null)
                return false
            }
            fileChooserCallback?.onReceiveValue(null)
            fileChooserCallback = filePathCallback
            val intent = fileChooserParams.createIntent().apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                if (fileChooserParams.mode == FileChooserParams.MODE_OPEN_MULTIPLE) {
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
            }
            return try {
                startActivityForResult(
                    Intent.createChooser(intent, fileChooserParams.title ?: "ফাইল নির্বাচন করুন"),
                    FILE_CHOOSER_REQUEST
                )
                true
            } catch (exception: Exception) {
                android.util.Log.e("AllApp", "Could not open the file chooser.", exception)
                fileChooserCallback = null
                filePathCallback.onReceiveValue(null)
                false
            }
        }

        override fun onCreateWindow(
            view: WebView,
            isDialog: Boolean,
            isUserGesture: Boolean,
            resultMsg: android.os.Message
        ): Boolean {
            if (!isUserGesture || Uri.parse(view.url).host != allowedHost) return false
            showPopupWebView(resultMsg)
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            handleWebPermissionRequest(target, request)
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            if (pendingWebPermissionRequest === request) {
                pendingWebPermissionRequest = null
            }
        }

        override fun onGeolocationPermissionsShowPrompt(
            origin: String,
            callback: GeolocationPermissions.Callback
        ) {
            handleGeolocationPermissionRequest(target, origin, callback)
        }
    }

    private fun handleWebPermissionRequest(target: WebView, request: PermissionRequest) {
        runOnUiThread {
            val origin = Uri.parse(request.origin.toString())
            val cameraOnly = request.resources.isNotEmpty() &&
                request.resources.all { it == PermissionRequest.RESOURCE_VIDEO_CAPTURE }
            if (Uri.parse(target.url).host != allowedHost ||
                origin.scheme != "https" ||
                origin.host != allowedHost ||
                !cameraOnly
            ) {
                request.deny()
                return@runOnUiThread
            }

            if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                request.grant(arrayOf(PermissionRequest.RESOURCE_VIDEO_CAPTURE))
                return@runOnUiThread
            }

            pendingWebPermissionRequest?.takeIf { it !== request }?.deny()
            pendingWebPermissionRequest = request
            requestPermissions(arrayOf(Manifest.permission.CAMERA), WEB_CAMERA_PERMISSION_REQUEST)
        }
    }

    private fun handleGeolocationPermissionRequest(
        target: WebView,
        origin: String,
        callback: GeolocationPermissions.Callback
    ) {
        runOnUiThread {
            val originUri = Uri.parse(origin)
            if (Uri.parse(target.url).host != allowedHost ||
                originUri.scheme != "https" ||
                originUri.host != allowedHost
            ) {
                callback.invoke(origin, false, false)
                return@runOnUiThread
            }

            if (hasLocationPermission()) {
                callback.invoke(origin, true, true)
                return@runOnUiThread
            }

            pendingGeolocationCallback?.invoke(pendingGeolocationOrigin.orEmpty(), false, false)
            pendingGeolocationOrigin = origin
            pendingGeolocationCallback = callback
            requestPermissions(
                arrayOf(
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                    Manifest.permission.ACCESS_FINE_LOCATION
                ),
                WEB_LOCATION_PERMISSION_REQUEST
            )
        }
    }

    private fun hasLocationPermission(): Boolean =
        checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun showPopupWebView(resultMsg: android.os.Message) {
        val popup = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.setGeolocationEnabled(true)
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(true)
            addJavascriptInterface(PrintBridge(this), PRINT_BRIDGE_NAME)
            addJavascriptInterface(ImageDownloadBridge(this), DOWNLOAD_BRIDGE_NAME)
            setDownloadListener(createDownloadListener())
        }
        val dialog = Dialog(this).apply {
            setContentView(popup)
            setOnDismissListener {
                popup.stopLoading()
                popup.destroy()
                popupDialogs.remove(this)
            }
        }
        popupDialogs.add(dialog)
        popup.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                handleWebPermissionRequest(popup, request)
            }

            override fun onPermissionRequestCanceled(request: PermissionRequest) {
                if (pendingWebPermissionRequest === request) {
                    pendingWebPermissionRequest = null
                }
            }

            override fun onGeolocationPermissionsShowPrompt(
                origin: String,
                callback: GeolocationPermissions.Callback
            ) {
                handleGeolocationPermissionRequest(popup, origin, callback)
            }

            override fun onCloseWindow(window: WebView) {
                dialog.dismiss()
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message
            ): Boolean {
                if (!isUserGesture || Uri.parse(view.url).host != allowedHost) return false
                showPopupWebView(resultMsg)
                return true
            }
        }
        popup.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                super.onPageFinished(view, url)
                if (Uri.parse(url).host == allowedHost) {
                    view.evaluateJavascript(WEB_DOWNLOAD_SCRIPT, null)
                }
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest
            ): Boolean {
                if (!request.isForMainFrame) return false
                return openExternalApp(request.url)
            }
        }
        dialog.show()
        dialog.window?.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        val transport = resultMsg.obj as? WebView.WebViewTransport ?: run {
            dialog.dismiss()
            return
        }
        transport.webView = popup
        resultMsg.sendToTarget()
    }

    private fun createDownloadListener() = DownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
        val uri = Uri.parse(url)
        if (uri.scheme != "https" && uri.scheme != "http") {
            Toast.makeText(this, "এই ফাইলটি ডাউনলোড করা যাচ্ছে না।", Toast.LENGTH_LONG).show()
            return@DownloadListener
        }
        val fileName = android.webkit.URLUtil.guessFileName(url, contentDisposition, mimeType)
        runWithStoragePermission {
            enqueueDownload(uri, userAgent, mimeType, fileName)
        }
    }

    private fun enqueueDownload(uri: Uri, userAgent: String, mimeType: String?, fileName: String) {
        try {
            val request = android.app.DownloadManager.Request(uri).apply {
                setTitle(fileName)
                setMimeType(mimeType)
                setNotificationVisibility(
                    android.app.DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED
                )
                setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS,
                    fileName
                )
                addRequestHeader("User-Agent", userAgent)
                CookieManager.getInstance().getCookie(uri.toString())?.let { addRequestHeader("Cookie", it) }
            }
            val manager = getSystemService(Context.DOWNLOAD_SERVICE) as android.app.DownloadManager
            manager.enqueue(request)
            Toast.makeText(this, "ডাউনলোড শুরু হয়েছে।", Toast.LENGTH_SHORT).show()
        } catch (exception: Exception) {
            android.util.Log.e("AllApp", "Could not start download.", exception)
            Toast.makeText(this, "ডাউনলোড শুরু করা যায়নি।", Toast.LENGTH_LONG).show()
        }
    }

    private fun runWithStoragePermission(action: () -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            action()
            return
        }
        if (pendingStorageAction != null) {
            Toast.makeText(this, "আগের ডাউনলোডের অনুমতির জন্য অপেক্ষা করুন।", Toast.LENGTH_SHORT).show()
            return
        }
        pendingStorageAction = action
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            STORAGE_PERMISSION_REQUEST
        )
    }

    private inner class PrintBridge(private val target: WebView) {
        @JavascriptInterface
        fun print() {
            runOnUiThread {
                if (Uri.parse(target.url).host != allowedHost) return@runOnUiThread
                val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
                printManager.print(
                    "AllApp",
                    target.createPrintDocumentAdapter("AllApp"),
                    null
                )
            }
        }
    }

    private inner class ImageDownloadBridge(private val target: WebView) {
        @JavascriptInterface
        fun saveFile(dataUrl: String, requestedName: String) {
            if (Uri.parse(target.url).host != allowedHost) return
            val match = Regex("^data:([A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=\\r\\n]+)$")
                .matchEntire(dataUrl)
            if (match == null || dataUrl.length > 64_000_000) {
                showImageDownloadResult("ফাইলটি সংরক্ষণ করা যায়নি।")
                return
            }
            try {
                val mimeType = match.groupValues[1]
                val image = Base64.decode(match.groupValues[2], Base64.DEFAULT)
                if (image.isEmpty()) throw IOException("The downloaded file is empty.")
                val fileName = normalizedDownloadName(requestedName, mimeType)
                runOnUiThread {
                    runWithStoragePermission {
                        try {
                            saveDownloadedBytes(image, fileName, mimeType)
                            val folder = if (mimeType.startsWith("image/")) {
                                "Pictures/AllApp"
                            } else {
                                "Downloads/AllApp"
                            }
                            showImageDownloadResult("ফাইলটি $folder ফোল্ডারে সংরক্ষণ হয়েছে।")
                        } catch (exception: Exception) {
                            android.util.Log.e("AllApp", "Could not save downloaded file.", exception)
                            showImageDownloadResult("ফাইলটি সংরক্ষণ করা যায়নি।")
                        }
                    }
                }
            } catch (exception: Exception) {
                android.util.Log.e("AllApp", "Could not decode downloaded file.", exception)
                showImageDownloadResult("ফাইলটি সংরক্ষণ করা যায়নি।")
            }
        }

        @JavascriptInterface
        fun reportFailure() {
            showImageDownloadResult("ফাইলটি সংরক্ষণ করা যায়নি।")
        }
    }

    private fun normalizedDownloadName(requestedName: String, mimeType: String): String {
        val safeName = requestedName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .trim('.', '_')
            .take(100)
            .ifBlank { "AllApp-download" }
        if (safeName.contains('.')) return safeName
        val extension = android.webkit.MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mimeType)
            ?.takeIf { it.matches(Regex("[A-Za-z0-9]{1,10}")) }
        return if (extension == null) safeName else "$safeName.$extension"
    }

    private fun saveDownloadedBytes(bytes: ByteArray, fileName: String, mimeType: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val directoryName = if (mimeType.startsWith("image/")) {
                Environment.DIRECTORY_PICTURES
            } else {
                Environment.DIRECTORY_DOWNLOADS
            }
            val directory = Environment.getExternalStoragePublicDirectory(directoryName)
                .resolve("AllApp")
            if (!directory.exists() && !directory.mkdirs()) {
                throw IOException("Could not create the download directory.")
            }
            val file = directory.resolve(fileName)
            FileOutputStream(file).use { it.write(bytes) }
            android.media.MediaScannerConnection.scanFile(
                this,
                arrayOf(file.absolutePath),
                arrayOf(mimeType),
                null
            )
            return
        }

        val isImage = mimeType.startsWith("image/")
        val collection = if (isImage) {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Downloads.EXTERNAL_CONTENT_URI
        }
        val folder = if (isImage) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_DOWNLOADS
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$folder/AllApp")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val fileUri = contentResolver.insert(collection, values)
            ?: throw IOException("Could not create the download file.")
        try {
            contentResolver.openOutputStream(fileUri, "w")?.use { it.write(bytes) }
                ?: throw IOException("Could not open the download file.")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            if (contentResolver.update(fileUri, values, null, null) == 0) {
                throw IOException("Could not finish saving the download.")
            }
        } catch (exception: Exception) {
            contentResolver.delete(fileUri, null, null)
            throw exception
        }
    }

    private fun showImageDownloadResult(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    private fun buildOfflineView(): LinearLayout {
        val density = resources.displayMetrics.density
        return LinearLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.WHITE)
            isClickable = true
            visibility = android.view.View.GONE
            addView(TextView(this@MainActivity).apply {
                text = getString(R.string.no_internet)
                textSize = 22f
                setTextColor(Color.BLACK)
                gravity = Gravity.CENTER
            })
            addView(Button(this@MainActivity).apply {
                text = getString(R.string.retry)
                isAllCaps = false
                textSize = 18f
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = (20 * density).toInt() }
                setOnClickListener { retryLoad() }
            })
        }
    }

    private fun showOffline(show: Boolean) {
        offlineView.visibility = if (show) android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun retryLoad() {
        val url = failedUrl ?: webView.url?.takeUnless { it == "about:blank" } ?: getString(R.string.app_url)
        webView.loadUrl(url)
    }

    private fun applyRecentsIcon() {
        val label = getString(R.string.app_name)
        val icon = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888)
        Canvas(icon).apply {
            drawColor(Color.rgb(16, 62, 67))
            val logo = resources.getDrawable(R.drawable.logo, theme)
            logo.setBounds(0, 0, icon.width, icon.height)
            logo.draw(this)
        }
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription(label, icon))
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    private inner class ContactPickerBridge {
        @JavascriptInterface
        fun pick(requestId: String, fieldsJson: String) {
            runOnUiThread {
                if (Uri.parse(webView.url).host != allowedHost) {
                    replyPicker(requestId, error = "Contact picker is only available on the app website.")
                    return@runOnUiThread
                }
                if (!requestId.matches(Regex("\\d+"))) {
                    return@runOnUiThread
                }
                if (pendingRequestId != null) {
                    replyPicker(requestId, error = "A contact picker is already open.")
                    return@runOnUiThread
                }

                val requestedFields = try {
                    val fields = JSONArray(fieldsJson)
                    (0 until fields.length())
                        .mapNotNull { fields.optString(it).takeIf(String::isNotBlank) }
                        .toSet()
                } catch (_: Exception) {
                    replyPicker(requestId, error = "Invalid contact fields.")
                    return@runOnUiThread
                }
                val supportedFields = requestedFields.intersect(setOf("name", "tel", "email"))
                if (supportedFields.none { it == "tel" || it == "email" }) {
                    replyPicker(requestId, error = "Select a phone number or email address.")
                    return@runOnUiThread
                }

                pendingRequestId = requestId
                pendingFields = supportedFields
                if (supportedFields == setOf("tel")) {
                    requestSimPickerPermissions()
                } else if ("email" in supportedFields && "tel" !in supportedFields) {
                    launchEmailAccountPicker()
                } else if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(
                        arrayOf(Manifest.permission.READ_CONTACTS),
                        CONTACT_PERMISSION_REQUEST
                    )
                } else {
                    launchContactPicker()
                }
            }

        }
    }

    private inner class LoginHistoryBridge {
        @JavascriptInterface
        fun read(): String {
            if (!isLoginPage()) return "{}"
            val prefs = getSharedPreferences(LOGIN_HISTORY_PREFS, Context.MODE_PRIVATE)
            return JSONObject()
                .put("email", prefs.getString(LOGIN_EMAIL_KEY, ""))
                .put("phone", prefs.getString(LOGIN_PHONE_KEY, ""))
                .toString()
        }

        @JavascriptInterface
        fun save(email: String, phone: String) {
            if (!isLoginPage()) return
            val editor = getSharedPreferences(LOGIN_HISTORY_PREFS, Context.MODE_PRIVATE).edit()
            if (email.isNotBlank()) editor.putString(LOGIN_EMAIL_KEY, email)
            if (phone.isNotBlank()) editor.putString(LOGIN_PHONE_KEY, phone)
            if (!editor.commit()) {
                android.util.Log.e("AllApp", "Could not persist login history.")
            }
        }
    }

    private fun isLoginPage(): Boolean {
        return loginPageActive
    }

    private fun requestSimPickerPermissions() {
        val requiredPermissions = buildList {
            add(Manifest.permission.READ_PHONE_STATE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                add(Manifest.permission.READ_PHONE_NUMBERS)
            }
        }
        val missingPermissions = requiredPermissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missingPermissions.isEmpty()) {
            showSimPicker()
        } else {
            requestPermissions(missingPermissions.toTypedArray(), SIM_PERMISSION_REQUEST)
        }
    }

    private fun showSimPicker() {
        try {
            val subscriptions = getSystemService(SubscriptionManager::class.java)
                .activeSubscriptionInfoList
                .orEmpty()
            val availableNumbers = subscriptions.mapNotNull { info ->
                val number = info.number?.trim()?.takeIf(String::isNotEmpty) ?: return@mapNotNull null
                info to number
            }
            if (availableNumbers.isEmpty()) {
                finishPicker(error = "No phone number is available from the SIM. Your carrier may not provide it.")
                return
            }

            val labels = availableNumbers.map { (info, number) ->
                val slot = getString(R.string.sim_slot_label, info.simSlotIndex + 1)
                val carrier = info.carrierName?.toString()?.takeIf(String::isNotBlank)
                listOfNotNull(slot, carrier, number).joinToString(" - ")
            }.toTypedArray()
            AlertDialog.Builder(this)
                .setTitle(R.string.sim_picker_title)
                .setItems(labels) { _, index ->
                    val number = availableNumbers[index].second
                    val selectedNumber = JSONObject().put("tel", JSONArray().put(number))
                    finishPicker(JSONArray().put(selectedNumber).toString())
                }
                .setOnCancelListener { finishPicker(JSONArray().toString()) }
                .show()
        } catch (exception: SecurityException) {
            finishPicker(error = exception.message ?: "SIM phone-number permission was denied.")
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not read SIM phone numbers.")
        }
    }

    private fun launchEmailAccountPicker() {
        try {
            val intent = AccountManager.newChooseAccountIntent(
                null,
                null,
                arrayOf("com.google"),
                null,
                null,
                null,
                null
            )
            startActivityForResult(intent, EMAIL_ACCOUNT_PICKER_REQUEST)
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not open the Google account picker.")
        }
    }

    private fun launchContactPicker() {
        try {
            startActivityForResult(
                Intent(Intent.ACTION_PICK, ContactsContract.Contacts.CONTENT_URI),
                CONTACT_PICKER_REQUEST
            )
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not open the contacts app.")
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == SIM_PERMISSION_REQUEST) {
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                showSimPicker()
            } else {
                finishPicker(error = "SIM permission was denied.")
            }
            return
        }
        if (requestCode == STORAGE_PERMISSION_REQUEST) {
            val action = pendingStorageAction
            pendingStorageAction = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                action?.invoke()
            } else {
                showImageDownloadResult("স্টোরেজ অনুমতি না দেওয়ায় ফাইল ডাউনলোড হয়নি।")
            }
            return
        }
        if (requestCode == WEB_CAMERA_PERMISSION_REQUEST) {
            val request = pendingWebPermissionRequest
            pendingWebPermissionRequest = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED &&
                request != null &&
                Uri.parse(request.origin.toString()).host == allowedHost &&
                request.resources.all { it == PermissionRequest.RESOURCE_VIDEO_CAPTURE }
            ) {
                request.grant(arrayOf(PermissionRequest.RESOURCE_VIDEO_CAPTURE))
            } else {
                request?.deny()
                Toast.makeText(this, "ক্যামেরা অনুমতি না দেওয়ায় QR স্ক্যান চালু হয়নি।", Toast.LENGTH_LONG).show()
            }
            return
        }
        if (requestCode == WEB_LOCATION_PERMISSION_REQUEST) {
            val origin = pendingGeolocationOrigin
            val callback = pendingGeolocationCallback
            pendingGeolocationOrigin = null
            pendingGeolocationCallback = null
            if (origin != null && callback != null &&
                grantResults.any { it == PackageManager.PERMISSION_GRANTED } &&
                Uri.parse(origin).host == allowedHost &&
                hasLocationPermission()
            ) {
                callback.invoke(origin, true, true)
            } else {
                callback?.invoke(origin.orEmpty(), false, false)
                Toast.makeText(this, "লোকেশন অনুমতি না দেওয়ায় এই সুবিধাটি চালু হয়নি।", Toast.LENGTH_LONG).show()
            }
            return
        }
        if (requestCode != CONTACT_PERMISSION_REQUEST) return

        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            launchContactPicker()
        } else {
            finishPicker(error = "Contacts permission was denied.")
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_CHOOSER_REQUEST) {
            val callback = fileChooserCallback ?: return
            fileChooserCallback = null
            val clip = data?.clipData
            val uris = if (resultCode == RESULT_OK && clip != null && clip.itemCount > 0) {
                Array(clip.itemCount) { clip.getItemAt(it).uri }
            } else {
                WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            }
            callback.onReceiveValue(uris)
            return
        }
        if (requestCode == EMAIL_ACCOUNT_PICKER_REQUEST) {
            val email = if (resultCode == RESULT_OK) {
                data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            } else {
                null
            }
            if (email.isNullOrBlank()) {
                finishPicker(JSONArray().toString())
            } else {
                val selectedAccount = JSONObject().put("email", JSONArray().put(email))
                finishPicker(JSONArray().put(selectedAccount).toString())
            }
            return
        }
        if (requestCode != CONTACT_PICKER_REQUEST) return

        val selectedUri = data?.data
        if (resultCode != RESULT_OK || selectedUri == null) {
            finishPicker(JSONArray().toString())
            return
        }

        try {
            finishPicker(readSelectedContact(selectedUri).toString())
        } catch (exception: Exception) {
            finishPicker(error = exception.message ?: "Could not read the selected contact.")
        }
    }

    private fun readSelectedContact(uri: Uri): JSONArray {
        val contact = JSONObject()
        val contactId = queryFirstValue(uri, ContactsContract.Contacts._ID)
            ?: throw IllegalStateException("The selected contact could not be read.")

        if ("name" in pendingFields) {
            val name = queryFirstValue(uri, ContactsContract.Contacts.DISPLAY_NAME)
            contact.put("name", JSONArray().apply { if (!name.isNullOrBlank()) put(name) })
        }
        if ("tel" in pendingFields) {
            contact.put(
                "tel",
                queryContactValues(
                    ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    contactId
                )
            )
        }
        if ("email" in pendingFields) {
            contact.put(
                "email",
                queryContactValues(
                    ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                    ContactsContract.CommonDataKinds.Email.ADDRESS,
                    contactId
                )
            )
        }
        return JSONArray().put(contact)
    }

    private fun queryFirstValue(uri: Uri, column: String): String? =
        contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(cursor.getColumnIndexOrThrow(column))
            } else {
                null
            }
        }

    private fun queryContactValues(uri: Uri, column: String, contactId: String): JSONArray {
        val values = JSONArray()
        contentResolver.query(
            uri,
            arrayOf(column),
            "${ContactsContract.Data.CONTACT_ID} = ?",
            arrayOf(contactId),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                cursor.getString(cursor.getColumnIndexOrThrow(column))
                    ?.takeIf(String::isNotBlank)
                    ?.let(values::put)
            }
        }
        return values
    }

    private fun finishPicker(result: String? = null, error: String? = null) {
        val requestId = pendingRequestId ?: return
        pendingRequestId = null
        pendingFields = emptySet()
        replyPicker(requestId, result, error)
    }

    private fun replyPicker(requestId: String, result: String? = null, error: String? = null) {
        val callback = if (error == null) {
            "window.__allappContactPickerResolve($requestId,${JSONObject.quote(result ?: "[]")})"
        } else {
            "window.__allappContactPickerReject($requestId,${JSONObject.quote(error)})"
        }
        webView.evaluateJavascript(callback, null)
    }

    // ---------------- In-app update from GitHub (jakirfile/allapp) ----------------
    private data class UpdateInfo(
        val versionCode: Long,
        val versionName: String,
        val apkUrl: String,
        val sha256: String
    )

    private data class InstalledVersion(
        val versionCode: Long,
        val versionName: String
    )

    private var updateCheckStarted = false
    private var pendingUpdate: UpdateInfo? = null
    // Update is mandatory: while this is set, the user is always brought back to the update dialog
    private var requiredUpdate: UpdateInfo? = null
    private var awaitingInstallPermission = false
    private var installReceiverRegistered = false

    private val installStatusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            when (status) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    if (confirm != null) {
                        try {
                            startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        } catch (exception: Exception) {
                            showUpdateError(exception.message ?: "Installer could not be opened.")
                        }
                    }
                }
                PackageInstaller.STATUS_SUCCESS -> Unit
                // User cancelled the system install screen: update is mandatory, ask again
                PackageInstaller.STATUS_FAILURE_ABORTED -> requiredUpdate?.let(::showUpdateDialog)
                else -> showUpdateError(message ?: "Install failed ($status).")
            }
        }
    }

    private fun installedVersion(): InstalledVersion {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0)
        }
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        return InstalledVersion(versionCode, info.versionName.orEmpty())
    }

    private fun checkForUpdate() {
        if (updateCheckStarted) return
        updateCheckStarted = true
        Thread {
            val info = try {
                fetchUpdateInfo()
            } catch (_: Exception) {
                null
            }
            val installed = installedVersion()
            if (
                info != null &&
                (info.versionCode != installed.versionCode || info.versionName != installed.versionName)
            ) {
                runOnUiThread {
                    if (!isFinishing && !isDestroyed) showUpdateDialog(info)
                }
            }
        }.start()
    }

    private fun fetchUpdateInfo(): UpdateInfo? {
        val url = URL(getString(R.string.update_manifest_url) + "?t=" + System.currentTimeMillis())
        val connection = (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 15000
            useCaches = false
            setRequestProperty("Cache-Control", "no-cache")
        }
        try {
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            val text = connection.inputStream.bufferedReader().use { it.readText() }.trimStart('﻿')
            val json = JSONObject(text)
            val versionCode = json.optLong("versionCode", -1L)
            val apkUrl = json.optString("apkUrl")
            val sha256 = json.optString("sha256").lowercase()
            if (versionCode < 1 || !apkUrl.startsWith("https://") || !sha256.matches(Regex("[0-9a-f]{64}"))) {
                return null
            }
            val versionName = json.optString("versionName").ifBlank { versionCode.toString() }
            return UpdateInfo(versionCode, versionName, apkUrl, sha256)
        } finally {
            connection.disconnect()
        }
    }

    private fun showUpdateDialog(info: UpdateInfo) {
        if (isFinishing || isDestroyed) return
        requiredUpdate = info
        AlertDialog.Builder(this)
            .setTitle(R.string.update_title)
            .setMessage(getString(R.string.update_message, info.versionName))
            .setPositiveButton(R.string.update_now) { _, _ -> startUpdate(info) }
            .setCancelable(false)
            .show()
    }

    private fun startUpdate(info: UpdateInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            pendingUpdate = info
            awaitingInstallPermission = true
            Toast.makeText(this, R.string.update_permission, Toast.LENGTH_LONG).show()
            try {
                openUnknownAppsSettings()
            } catch (exception: Exception) {
                awaitingInstallPermission = false
                pendingUpdate = null
                showUpdateError(exception.message ?: getString(R.string.update_permission_denied))
            }
            return
        }
        downloadAndInstall(info)
    }

    override fun onResume() {
        super.onResume()
        if (!awaitingInstallPermission) return
        awaitingInstallPermission = false
        val info = pendingUpdate ?: return
        pendingUpdate = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            downloadAndInstall(info)
        } else {
            showUpdateError(getString(R.string.update_permission_denied))
        }
    }

    private fun saveResumePoint() {
        val url = webView.url ?: return
        if (Uri.parse(url).host != allowedHost) return
        val installed = installedVersion()
        getSharedPreferences(RESUME_PREFS, Context.MODE_PRIVATE).edit()
            .putString(RESUME_URL_KEY, url)
            .putLong(RESUME_FROM_CODE_KEY, installed.versionCode)
            .putString(RESUME_FROM_NAME_KEY, installed.versionName)
            .commit()
    }

    /** Returns the saved page only if the app was actually updated since it was saved. */
    private fun consumeResumeUrl(): String? {
        val prefs = getSharedPreferences(RESUME_PREFS, Context.MODE_PRIVATE)
        val url = prefs.getString(RESUME_URL_KEY, null) ?: return null
        val fromCode = prefs.getLong(RESUME_FROM_CODE_KEY, Long.MAX_VALUE)
        val fromName = prefs.getString(RESUME_FROM_NAME_KEY, null)
        val installed = installedVersion()
        if (installed.versionCode == fromCode && installed.versionName == fromName) {
            return null // update not installed yet; keep it for later
        }
        prefs.edit().clear().apply()
        return url.takeIf { Uri.parse(it).host == allowedHost }
    }

    private fun downloadAndInstall(info: UpdateInfo) {
        saveResumePoint()
        registerInstallReceiver()
        val progressDialog = AlertDialog.Builder(this)
            .setTitle(R.string.update_title)
            .setMessage(getString(R.string.update_downloading, 0))
            .setCancelable(false)
            .show()
        Thread {
            val apkFile = File(cacheDir, "allapp-update.apk")
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                val apkUrl = Uri.parse(info.apkUrl)
                    .buildUpon()
                    .appendQueryParameter("t", System.currentTimeMillis().toString())
                    .build()
                    .toString()
                val connection = (URL(apkUrl).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 20000
                    readTimeout = 30000
                    useCaches = false
                    setRequestProperty("Cache-Control", "no-cache, no-store")
                    setRequestProperty("Pragma", "no-cache")
                }
                try {
                    if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                        throw IOException("HTTP ${connection.responseCode}")
                    }
                    val total = connection.contentLengthLong
                    var done = 0L
                    var lastPercent = -1
                    connection.inputStream.use { input ->
                        FileOutputStream(apkFile).use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                output.write(buffer, 0, read)
                                digest.update(buffer, 0, read)
                                done += read
                                if (total > 0) {
                                    val percent = (done * 100 / total).toInt()
                                    if (percent != lastPercent) {
                                        lastPercent = percent
                                        runOnUiThread {
                                            progressDialog.setMessage(getString(R.string.update_downloading, percent))
                                        }
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                }
                val actualSha = digest.digest().joinToString("") {
                    "%02x".format(it.toInt() and 0xff)
                }
                if (actualSha != info.sha256) {
                    throw IOException(getString(R.string.update_hash_mismatch, actualSha, info.sha256))
                }

                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(packageName)
                }
                val sessionId = installer.createSession(params)
                installer.openSession(sessionId).use { session ->
                    apkFile.inputStream().use { input ->
                        session.openWrite("base.apk", 0, apkFile.length()).use { output ->
                            input.copyTo(output)
                            session.fsync(output)
                        }
                    }
                    val statusIntent = Intent(ACTION_INSTALL_STATUS).setPackage(packageName)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
                    val pendingIntent = PendingIntent.getBroadcast(this, sessionId, statusIntent, flags)
                    session.commit(pendingIntent.intentSender)
                }
                runOnUiThread {
                    if (!isDestroyed) progressDialog.dismiss()
                }
            } catch (exception: Exception) {
                apkFile.delete()
                runOnUiThread {
                    if (!isDestroyed) progressDialog.dismiss()
                    showUpdateError(exception.message ?: exception.javaClass.simpleName)
                }
            }
        }.start()
    }

    private fun registerInstallReceiver() {
        if (installReceiverRegistered) return
        val filter = IntentFilter(ACTION_INSTALL_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(installStatusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(installStatusReceiver, filter)
        }
        installReceiverRegistered = true
    }

    private fun isInstallPermissionError(message: String): Boolean {
        val normalized = message.lowercase()
        return normalized.contains("permission") ||
            normalized.contains("install_failed_") ||
            normalized.contains("ed_internal_error")
    }

    private fun openUnknownAppsSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
            )
        } catch (exception: Exception) {
            showUpdateError(exception.message ?: getString(R.string.update_permission_denied))
        }
    }

    private fun showUpdateError(message: String) {
        if (isFinishing || isDestroyed) return
        val installPermissionError = isInstallPermissionError(message)
        val miuiInstallRejected =
            installPermissionError &&
                Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true) &&
                message.contains("permission", ignoreCase = true)
        val dialogMessage = buildString {
            append(getString(R.string.update_failed, message))
            if (miuiInstallRejected) {
                append("\n\n")
                append(getString(R.string.update_miui_install_help))
            }
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.update_title)
            .setMessage(dialogMessage)
            .setCancelable(false)
        if (miuiInstallRejected) {
            dialog.setPositiveButton(R.string.update_open_installer) { _, _ ->
                openDownloadedApkInstaller()
            }
            dialog.setNegativeButton(android.R.string.cancel) { _, _ ->
                requiredUpdate?.let(::showUpdateDialog)
            }
        } else if (installPermissionError) {
            dialog.setPositiveButton(android.R.string.ok) { _, _ ->
                openUnknownAppsSettings()
            }
        } else {
            dialog.setPositiveButton(android.R.string.ok) { _, _ ->
                // Mandatory update: go back to the update dialog until it is installed
                requiredUpdate?.let(::showUpdateDialog)
            }
        }
        dialog.show()
    }

    private fun openDownloadedApkInstaller() {
        val apkFile = File(cacheDir, "allapp-update.apk")
        if (!apkFile.isFile) {
            showUpdateError("The downloaded update APK is no longer available.")
            return
        }

        val apkUri = Uri.parse("content://$packageName.updateprovider/allapp-update.apk")
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (exception: Exception) {
            showUpdateError(exception.message ?: "System installer could not be opened.")
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        pendingWebPermissionRequest?.deny()
        pendingWebPermissionRequest = null
        pendingGeolocationCallback?.invoke(pendingGeolocationOrigin.orEmpty(), false, false)
        pendingGeolocationCallback = null
        pendingGeolocationOrigin = null
        popupDialogs.toList().forEach(Dialog::dismiss)
        if (installReceiverRegistered) {
            try {
                unregisterReceiver(installStatusReceiver)
            } catch (_: Exception) {
            }
            installReceiverRegistered = false
        }
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }
}
