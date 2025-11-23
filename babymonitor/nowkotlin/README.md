# Now ESP32 Cam

An Android app written in Kotlin that previews an ESP32-CAM video stream by loading the device's MJPEG URL. The app lets you type the ESP32 camera address, stores it for quick reconnects, and provides pull-to-refresh support when the stream stalls.

## Features

-  Save and reuse the ESP32 camera stream URL.
-  Simple one-tap connect button to start streaming.
-  Pull to refresh the WebView if the stream stops.
-  Cleartext HTTP access enabled for typical ESP32 setups.

## Requirements

-  Android Studio Hedgehog (or newer) with Android Gradle Plugin 8.5+
-  Android device (or emulator) running Android 7.0 (API 24) or later.

## Getting Started

1. Open the project in Android Studio.
2. Let Gradle sync resolve dependencies.
3. Connect a device or start an emulator.
4. Run the `app` configuration.
5. On first launch, type the ESP32-CAM stream URL (for example `http://192.168.4.1:81/stream`) and tap **Connect**.
