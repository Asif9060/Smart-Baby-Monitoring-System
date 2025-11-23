# Camera Stream Debug Guide

If the camera feed is still spinning, follow these steps:

## 1. Test in Browser First

Open your browser and try these URLs (replace 192.168.1.X with your camera IP):

-  `http://192.168.1.X/` → If this shows the camera feed, that's the working URL
-  `http://192.168.1.X:81/` → Alternative port
-  `http://192.168.1.X/stream` → Common ESP32 default
-  `http://192.168.1.X:81/stream` → Alternative port with stream

Write down which one works.

## 2. Manually Set in App

Once you know the working URL in the browser:

1. Launch the app on your Android device
2. Look for the "Set address" button on the camera feed card
3. Tap it and enter the exact URL that worked in your browser
   -  Example: `192.168.1.X` or `http://192.168.1.X:81`
4. Tap "Use"

## 3. If Still Spinning

The app now tries these candidates automatically:

-  Original URL
-  URL with `/stream` appended
-  URL at root `/`
-  Port 81 variant
-  Port 81 with `/stream`

If none work, the actual error will display (instead of just spinning).

## 4. Common ESP32-CAM Issues

-  Default stream endpoint is often at `http://192.168.1.X/stream` (NOT `/`)
-  Some boards use port `81`
-  Headers matter: app sends `Accept: multipart/x-mixed-replace`
-  If you see "boundary missing" error, your ESP32 isn't sending proper MJPEG headers

## 5. Firebase Auto-Config

The app tries to fetch camera URL from Firebase path: `/esp32cam/`
If your device publishes the correct IP/URL there, it will load automatically.
Otherwise, use "Set address" to override.
