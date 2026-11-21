package org.christersson.uwmedia.spike

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val engine = SpikeEngine(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uwmedia.spike/engine")
            .setMethodCallHandler(engine::handle)
    }
}
