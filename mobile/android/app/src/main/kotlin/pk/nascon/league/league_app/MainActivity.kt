package pk.nascon.league.league_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Hands nascon:// deep links (spec 6.3) to Dart: the launch link on request, later ones as they arrive. */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nascon/deeplink").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "getInitialLink") result.success(takeLink(intent)) else result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeLink(intent)?.let { channel?.invokeMethod("onLink", it) }
    }

    /** A link is used once. Android re-delivers the original intent when the app is reopened from Recents
     *  (after the process was killed), which must open the normal start screen, not the old deep link again. */
    private fun takeLink(intent: Intent?): String? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val link = intent.dataString
        intent.data = null
        return link
    }
}
