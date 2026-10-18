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
                if (call.method == "getInitialLink") result.success(intent?.dataString) else result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { channel?.invokeMethod("onLink", it) }
    }
}
