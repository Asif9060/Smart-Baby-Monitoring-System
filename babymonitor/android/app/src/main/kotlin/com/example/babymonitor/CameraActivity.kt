package com.example.babymonitor

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.util.Patterns
import android.view.View
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.addCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.widget.doAfterTextChanged
import androidx.preference.PreferenceManager
import com.example.babymonitor.databinding.ActivityCameraBinding
import kotlin.math.min

class CameraActivity : AppCompatActivity() {

    private lateinit var binding: ActivityCameraBinding

    // Track stream URL candidates and current attempt for fallback behavior
    private var currentCandidates: List<String> = emptyList()
    private var currentAttemptIndex: Int = 0
    private var currentBaseUrl: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityCameraBinding.inflate(layoutInflater)
        setContentView(binding.root)
        updateStatus(Status.Idle)

        // Ensure the stream view is a centered square covering up to half of the screen
        setupSquareSizing()

        val prefs = PreferenceManager.getDefaultSharedPreferences(this)
        val lastUrl = prefs.getString(KEY_STREAM_URL, "")
        binding.urlInput.setText(lastUrl)
        binding.loadStreamButton.isEnabled = !lastUrl.isNullOrBlank()

        configureWebView(binding.streamWebView)

        val primaryColor = ContextCompat.getColor(this, R.color.primary)
        val surfaceColor = ContextCompat.getColor(this, R.color.surface)
        binding.streamContainer.setColorSchemeColors(primaryColor)
        binding.streamContainer.setProgressBackgroundColorSchemeColor(surfaceColor)

        binding.urlInput.doAfterTextChanged {
            binding.loadStreamButton.isEnabled = !it.isNullOrBlank()
            if (binding.urlInputLayout.error != null) {
                binding.urlInputLayout.error = null
            }
        }

        binding.loadStreamButton.setOnClickListener {
            val entered = binding.urlInput.text?.toString()?.trim().orEmpty()
            val sanitized = sanitizeUrl(entered)
            if (sanitized == null) {
                binding.urlInputLayout.error = getString(R.string.invalid_url)
                Toast.makeText(this, R.string.invalid_url, Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }

            // Persist base URL and load stream via candidates
            prefs.edit { putString(KEY_STREAM_URL, sanitized) }
            loadStream(sanitized, showLoading = true)
        }

        binding.streamContainer.setOnRefreshListener {
            val base = currentBaseUrl ?: PreferenceManager.getDefaultSharedPreferences(this)
                .getString(KEY_STREAM_URL, null)
            if (base.isNullOrBlank()) {
                binding.streamContainer.isRefreshing = false
                return@setOnRefreshListener
            }
            loadStream(base, showLoading = false)
        }

        if (!lastUrl.isNullOrBlank()) {
            loadStream(lastUrl, showLoading = false)
        }

        onBackPressedDispatcher.addCallback(this) {
            if (binding.streamWebView.canGoBack()) {
                binding.streamWebView.goBack()
            } else {
                isEnabled = false
                onBackPressedDispatcher.onBackPressed()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        binding.streamWebView.onResume()
    }

    override fun onPause() {
        binding.streamWebView.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        // Explicitly tear down the WebView to avoid leaking the activity context.
        binding.streamWebView.apply {
            loadUrl("about:blank")
            stopLoading()
            // Assign default lightweight clients to break references without using null
            webChromeClient = WebChromeClient()
            webViewClient = WebViewClient()
            destroy()
        }
        super.onDestroy()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView(webView: WebView) {
        webView.apply {
            settings.apply {
                javaScriptEnabled = false
                cacheMode = WebSettings.LOAD_NO_CACHE
                domStorageEnabled = false
                builtInZoomControls = true
                displayZoomControls = false
                loadWithOverviewMode = true
                useWideViewPort = true
                loadsImagesAutomatically = true
            }

            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    // Keep navigation inside the WebView
                    return false
                }

                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    updateStatus(Status.Loading)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    binding.loadingIndicator.visibility = View.GONE
                    binding.streamContainer.isRefreshing = false
                    updateStatus(Status.Connected)
                }

                override fun onReceivedError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    error: WebResourceError?
                ) {
                    if (request?.isForMainFrame == true) {
                        // Try next candidate if available
                        val nextIdx = currentAttemptIndex + 1
                        if (nextIdx < currentCandidates.size) {
                            tryLoadCandidate(nextIdx)
                        } else {
                            binding.loadingIndicator.visibility = View.GONE
                            binding.streamContainer.isRefreshing = false
                            updateStatus(Status.Error)
                            Toast.makeText(
                                this@CameraActivity,
                                getString(R.string.status_error),
                                Toast.LENGTH_SHORT
                            ).show()
                        }
                    }
                }
            }
        }
    }

    private fun loadStream(baseUrl: String, showLoading: Boolean) {
        currentBaseUrl = baseUrl
        currentCandidates = buildCandidates(baseUrl)
        currentAttemptIndex = 0
        if (showLoading) {
            binding.loadingIndicator.visibility = View.VISIBLE
            updateStatus(Status.Loading)
        }
        binding.streamContainer.isRefreshing = false
        tryLoadCandidate(0)
    }

    private fun tryLoadCandidate(index: Int) {
        currentAttemptIndex = index
        val url = currentCandidates.getOrNull(index) ?: return
        binding.streamWebView.stopLoading()
        binding.streamWebView.loadUrl(url)
    }

    private fun buildCandidates(input: String): List<String> {
        val normalized = sanitizeUrl(input) ?: input
        return try {
            val uri = Uri.parse(normalized)
            val scheme = uri.scheme ?: "http"
            val host = uri.host ?: normalized
            val inputPort = uri.port
            val basePort = if (inputPort != -1) ":$inputPort" else ""
            val base = "$scheme://$host$basePort"
            val list = mutableListOf<String>()

            // If user already points to a stream, use as-is first
            if (uri.path?.contains("stream") == true) {
                list += normalized
            } else {
                list += "$base/stream"
            }

            // If not already port 81, add a candidate for :81/stream
            if (inputPort != 81) {
                list += "$scheme://$host:81/stream"
            }

            // De-dupe while preserving order
            list.distinct()
        } catch (t: Throwable) {
            // Best-effort fallbacks
            val primary = if (normalized.endsWith("/stream")) normalized else "$normalized/stream"
            listOf(primary, primary.replace(":80/", ":81/").replace("//stream", ":81/stream"))
                .distinct()
        }
    }

    private fun setupSquareSizing() {
        // Recalculate when the root layout changes size (orientation, window insets, etc.)
        binding.root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> adjustStreamSquare() }
        // Initial pass
        binding.root.post { adjustStreamSquare() }
    }

    private fun adjustStreamSquare() {
        val contW = binding.streamContainer.width
        val contH = binding.streamContainer.height
        if (contW == 0 || contH == 0) return
        val side = min(contW, contH)
        val lp = binding.streamWebView.layoutParams
        if (lp is ConstraintLayout.LayoutParams) {
            lp.width = side
            lp.height = side
            lp.topToTop = ConstraintLayout.LayoutParams.PARENT_ID
            lp.bottomToBottom = ConstraintLayout.LayoutParams.PARENT_ID
            lp.startToStart = ConstraintLayout.LayoutParams.PARENT_ID
            lp.endToEnd = ConstraintLayout.LayoutParams.PARENT_ID
            binding.streamWebView.layoutParams = lp
        } else {
            lp.width = side
            lp.height = side
            binding.streamWebView.layoutParams = lp
        }
    }

    private fun updateStatus(status: Status) {
        val text = when (status) {
            Status.Idle -> R.string.status_idle
            Status.Loading -> R.string.status_loading
            Status.Connected -> R.string.status_connected
            Status.Error -> R.string.status_error
        }
        binding.statusText.setText(text)
        if (status == Status.Error) {
            binding.loadingIndicator.visibility = View.GONE
            binding.streamContainer.isRefreshing = false
        }
    }

    private fun sanitizeUrl(input: String): String? {
        if (input.isBlank()) return null
        val candidate = if (input.startsWith("http", ignoreCase = true)) {
            input
        } else {
            "http://$input"
        }
        return if (Patterns.WEB_URL.matcher(candidate).matches()) candidate else null
    }

    private enum class Status {
        Idle,
        Loading,
        Connected,
        Error
    }

    companion object {
        private const val KEY_STREAM_URL = "camera_stream_url"
    }
}
