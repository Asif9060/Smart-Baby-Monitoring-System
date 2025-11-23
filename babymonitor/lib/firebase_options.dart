import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Manually generated Firebase configuration based on the provided
/// `google-services.json`. Only Android is configured; add additional
/// platform entries if you register them in Firebase later.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError(
          'FirebaseOptions for ${defaultTargetPlatform.name} have not been configured. '
          'Register the platform in Firebase and update firebase_options.dart.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBm8tca-B2hlM8-nJgbdzBwBHNyVDX7lxo',
    appId: '1:136907588165:android:d1b175a70d721952c6992c',
    messagingSenderId: '136907588165',
    projectId: 'babymonitor-9ea16',
    databaseURL: 'https://babymonitor-9ea16-default-rtdb.firebaseio.com',
    storageBucket: 'babymonitor-9ea16.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBe5_FAPhr9v3HyRU4CtFjEMG6_-ALLMjU',
    appId: '1:136907588165:web:8e4365e9dbd78b22c6992c',
    messagingSenderId: '136907588165',
    projectId: 'babymonitor-9ea16',
    authDomain: 'babymonitor-9ea16.firebaseapp.com',
    databaseURL: 'https://babymonitor-9ea16-default-rtdb.firebaseio.com',
    storageBucket: 'babymonitor-9ea16.firebasestorage.app',
    measurementId: 'G-F46BLS9C4T',
  );
}
