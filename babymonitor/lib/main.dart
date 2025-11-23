import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    runApp(const BabyMonitorApp());
  } catch (e, stack) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Initialization Error:\n$e\n\n$stack',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BabyMonitorApp extends StatelessWidget {
  const BabyMonitorApp({super.key, this.overrideStream});

  final Stream<DatabaseEvent>? overrideStream;

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5F7FF5)),
      useMaterial3: true,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Baby Monitoring',
      builder: (context, child) {
        ErrorWidget.builder = (FlutterErrorDetails details) {
          return Scaffold(
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Rendering Error:\n${details.exception}\n\n${details.stack}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          );
        };
        return child!;
      },
      theme: baseTheme.copyWith(
        textTheme: GoogleFonts.plusJakartaSansTextTheme(baseTheme.textTheme),
        appBarTheme: baseTheme.appBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: baseTheme.colorScheme.onSurface,
          centerTitle: false,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FD),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
        ),
      ),
      home: BabyMonitorPage(overrideStream: overrideStream),
    );
  }
}

class BabyMonitorPage extends StatefulWidget {
  const BabyMonitorPage({super.key, this.overrideStream});

  final Stream<DatabaseEvent>? overrideStream;

  @override
  State<BabyMonitorPage> createState() => _BabyMonitorPageState();
}

class _BabyMonitorPageState extends State<BabyMonitorPage> {
  static const String monitorPath = 'devices';
  DatabaseReference? _monitorRef;
  StreamSubscription<DatabaseEvent>? _monitorSubscription;
  String? _manualCameraUrl;
  BabyMonitorReadings? _readings;
  Object? _error;
  bool _loading = true;
  List<ActivityEvent> _todayActivities = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupNotificationChannel();
    _loadTodayActivities();
    
    final override = widget.overrideStream;
    if (override != null) {
      _subscribeToStream(override);
    } else {
      final ref = FirebaseDatabase.instance.ref(monitorPath);
      if (!kIsWeb) {
        ref.keepSynced(true);
      }
      _monitorRef = ref;
      _subscribeToStream(ref.onValue);
    }
  }

  Future<void> _loadTodayActivities() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final todayKey = '${today.year}-${today.month}-${today.day}';
    final lastSavedDay = prefs.getString('last_activity_day');

    // Reset if it's a new day
    if (lastSavedDay != todayKey) {
      await prefs.setString('last_activity_day', todayKey);
      await prefs.remove('today_activities');
      if (mounted) {
        setState(() {
          _todayActivities = [];
        });
      }
      return;
    }

    // Load existing activities
    final activitiesJson = prefs.getString('today_activities');
    if (activitiesJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(activitiesJson);
        if (mounted) {
          setState(() {
            _todayActivities = decoded
                .map((json) => ActivityEvent.fromJson(json))
                .toList();
          });
        }
      } catch (e) {
        debugPrint('Error loading activities: $e');
      }
    }
  }

  Future<void> _saveActivity(ActivityEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    _todayActivities.insert(0, event); // Add to beginning
    
    // Keep only last 100 activities
    if (_todayActivities.length > 100) {
      _todayActivities = _todayActivities.sublist(0, 100);
    }

    final activitiesJson = jsonEncode(
      _todayActivities.map((e) => e.toJson()).toList(),
    );
    await prefs.setString('today_activities', activitiesJson);

    if (mounted) {
      setState(() {});
    }
  }

  void _subscribeToStream(Stream<DatabaseEvent> stream) {
    _monitorSubscription = stream.listen(
      (event) {
        if (event.snapshot.value == null) {
          if (mounted) {
            setState(() {
              _loading = false;
              _readings = null; // Empty state
            });
          }
          return;
        }

        final newReadings = BabyMonitorReadings.fromSnapshot(
          event.snapshot,
          receivedAt: DateTime.now(),
        );

        if (_readings != null) {
          _checkNotifications(newReadings, _readings!);
        }

        if (mounted) {
          setState(() {
            _readings = newReadings;
            _loading = false;
            _error = null;
          });
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            _error = error;
            _loading = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _monitorSubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidImplementation?.requestNotificationsPermission();
  }

  Future<void> _setupNotificationChannel() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'baby_monitor_alerts', // id
      'Baby Monitor Alerts', // title
      description: 'Notifications for motion, sound, and temperature alerts',
      importance: Importance.max,
      playSound: true,
    );

    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidImplementation?.createNotificationChannel(channel);
  }

  Future<void> _showNotification(String title, String body) async {
    const AndroidNotificationDetails androidNotificationDetails =
        AndroidNotificationDetails(
          'baby_monitor_alerts',
          'Baby Monitor Alerts',
          channelDescription: 'Notifications for motion, sound, and temperature alerts',
          importance: Importance.max,
          priority: Priority.high,
          ticker: 'ticker',
          playSound: true,
        );
    const NotificationDetails notificationDetails = NotificationDetails(
      android: androidNotificationDetails,
    );
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecond,
      title,
      body,
      notificationDetails,
    );
  }

  void _checkNotifications(
    BabyMonitorReadings current,
    BabyMonitorReadings previous,
  ) {
    // Motion
    if (current.motionDetected == true && previous.motionDetected != true) {
      _showNotification(
        'Motion Detected',
        'Motion has been detected in the App.',
      );
      _saveActivity(ActivityEvent(
        type: ActivityType.motion,
        timestamp: DateTime.now(),
        description: 'Motion detected in the nursery',
      ));
    }

    // Sound
    if (current.soundAlert == true && previous.soundAlert != true) {
      _showNotification('Sound Alert', 'Loud noise detected in the App.');
      _saveActivity(ActivityEvent(
        type: ActivityType.sound,
        timestamp: DateTime.now(),
        description: 'Loud noise detected (${current.soundDecibels})',
      ));
    }

    // Temperature
    if (current.temperature != null) {
      if (current.temperature! >= 28 &&
          (previous.temperature == null || previous.temperature! < 28)) {
        _showNotification(
          'High Temperature',
          'Sorrounding temperature is high (${current.temperatureCelsius}).',
        );
        _saveActivity(ActivityEvent(
          type: ActivityType.temperature,
          timestamp: DateTime.now(),
          description: 'High temperature alert (${current.temperatureCelsius})',
        ));
      } else if (current.temperature! < 20 &&
          (previous.temperature == null || previous.temperature! >= 20)) {
        _showNotification(
          'Low Temperature',
          'Sorrounding temperature is low (${current.temperatureCelsius}).',
        );
        _saveActivity(ActivityEvent(
          type: ActivityType.temperature,
          timestamp: DateTime.now(),
          description: 'Low temperature alert (${current.temperatureCelsius})',
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Baby Monitoring',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'Live feed & Baby vitals',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh now',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              final ref = _monitorRef;
              if (ref != null) {
                await ref.get();
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_error != null) {
            return _ErrorState(message: _error.toString());
          }

          if (_loading) {
            return const _LoadingState();
          }

          final readings = _readings;
          if (readings == null) {
            return const _EmptyState();
          }

          return BabyMonitorView(
            readings: readings,
            todayActivities: _todayActivities,
            manualCameraOverride: _manualCameraUrl,
            onRequestManualCameraUrl: () => _promptManualCameraUrl(
              initialValue:
                  _manualCameraUrl ?? readings.liveFeedUrl ?? readings.cameraIp,
            ),
            onClearManualCameraUrl: _manualCameraUrl == null
                ? null
                : () => setState(() {
                    _manualCameraUrl = null;
                  }),
          );
        },
      ),
    );
  }

  Future<void> _promptManualCameraUrl({String? initialValue}) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Set camera address'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Camera URL or IP',
              hintText: 'e.g. 192.168.1.42',
            ),
            keyboardType: TextInputType.url,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(''),
              child: const Text('Clear'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Use'),
            ),
          ],
        );
      },
    );

    if (!mounted || result == null) {
      return;
    }

    setState(() {
      _manualCameraUrl = result.isEmpty ? null : result;
    });
  }
}

class BabyMonitorView extends StatelessWidget {
  const BabyMonitorView({
    super.key,
    required this.readings,
    required this.todayActivities,
    this.manualCameraOverride,
    this.onRequestManualCameraUrl,
    this.onClearManualCameraUrl,
  });

  final BabyMonitorReadings readings;
  final List<ActivityEvent> todayActivities;
  final String? manualCameraOverride;
  final VoidCallback? onRequestManualCameraUrl;
  final VoidCallback? onClearManualCameraUrl;

  @override
  Widget build(BuildContext context) {
    final effectiveStreamUrl = manualCameraOverride ?? readings.liveFeedUrl;
    final cameraLabel =
        manualCameraOverride ?? readings.cameraIp ?? readings.liveFeedUrl;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      children: [
        _DashboardHeader(
          lastUpdated: readings.lastUpdated,
          isOnline: readings.isOnline,
          deviceIp: readings.deviceIp,
        ),
        const SizedBox(height: 16),
        DeviceStatusCard(
          isOnline: readings.isOnline,
          deviceIp: readings.deviceIp,
          cameraStreamUrl: readings.liveFeedUrl,
          cameraIp: readings.cameraIp,
        ),
        const SizedBox(height: 20),
        LiveFeedCard(
          liveFeedUrl: effectiveStreamUrl,
          cameraLabel: cameraLabel,
          onEnterManualUrl: onRequestManualCameraUrl,
          onClearManualUrl: onClearManualCameraUrl,
        ),
        const SizedBox(height: 24),
        SensorGrid(readings: readings),
        const SizedBox(height: 24),
        DailyActivityHistoryCard(activities: todayActivities),
        const SizedBox(height: 24),
        MotionStatusCard(
          isMotionDetected: readings.motionDetected,
          isDeviceOnline: readings.isOnline,
          lastUpdated: readings.lastUpdated,
        ),
      ],
    );
  }
}

class DeviceStatusCard extends StatelessWidget {
  const DeviceStatusCard({
    super.key,
    this.isOnline,
    this.deviceIp,
    this.cameraStreamUrl,
    this.cameraIp,
  });

  final bool? isOnline;
  final String? deviceIp;
  final String? cameraStreamUrl;
  final String? cameraIp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = isOnline ?? false;
    final title = online ? 'Monitor online' : 'Monitor offline';
    final subtitle = online
        ? 'Baby monitor is publishing telemetry to Firebase.'
        : 'Waiting for the monitor to reconnect.';
    final statusColor = online
        ? const Color(0xFF3CC687)
        : theme.colorScheme.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: _withOpacityFactor(statusColor, 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    online ? Icons.sensors_rounded : Icons.sensors_off,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatusChip(
                  icon: online ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                  label: online ? 'Wi-Fi connected' : 'Wi-Fi unavailable',
                  color: statusColor,
                ),
                if (deviceIp != null)
                  _StatusChip(
                    icon: Icons.memory_rounded,
                    label: 'Monitor IP · $deviceIp',
                  ),
                if (cameraStreamUrl != null)
                  _StatusChip(
                    icon: Icons.videocam_rounded,
                    label: 'Camera stream · $cameraStreamUrl',
                  )
                else if (cameraIp != null)
                  _StatusChip(
                    icon: Icons.videocam_rounded,
                    label: 'Camera IP · $cameraIp',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = color ?? theme.colorScheme.outline;
    final background = _withOpacityFactor(baseColor, 0.12);
    final foreground = color ?? theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.lastUpdated,
    this.isOnline,
    this.deviceIp,
  });

  final DateTime? lastUpdated;
  final bool? isOnline;
  final String? deviceIp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = isOnline ?? false;
    final statusColor = connected
        ? const Color(0xFF3CC687)
        : theme.colorScheme.error;
    final statusText = connected ? 'Monitor online' : 'Monitor offline';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Baby Overview',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              _formatRelativeTime(lastUpdated),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              statusText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (deviceIp != null) ...[
              const SizedBox(width: 12),
              Text(
                'IP $deviceIp',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class LiveFeedCard extends StatelessWidget {
  const LiveFeedCard({
    super.key,
    required this.liveFeedUrl,
    this.cameraLabel,
    this.onEnterManualUrl,
    this.onClearManualUrl,
  });

  final String? liveFeedUrl;
  final String? cameraLabel;
  final VoidCallback? onEnterManualUrl;
  final VoidCallback? onClearManualUrl;

  static const platform = MethodChannel(
    'com.example.babymonitor/camera_control',
  );

  Future<void> _launchCamera() async {
    try {
      await platform.invokeMethod('launchCamera');
    } on PlatformException catch (e) {
      debugPrint('Failed to launch camera: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 240,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Theme.of(context).colorScheme.primaryContainer,
                    Theme.of(context).colorScheme.secondaryContainer,
                  ],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.videocam,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _launchCamera,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open Camera View'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (liveFeedUrl != null && liveFeedUrl!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Camera: $liveFeedUrl',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 16,
              child: const _LiveBadge(label: 'Native'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _withOpacityFactor(theme.colorScheme.onSurface, 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.live_tv_rounded, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveFeedError extends StatelessWidget {
  const _LiveFeedError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: _withOpacityFactor(Colors.black, 0.55),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Colors.white,
            size: 36,
          ),
          const SizedBox(height: 12),
          Text(
            'Unable to load camera stream',
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _BrowserLikeCameraView extends StatefulWidget {
  const _BrowserLikeCameraView({required this.url});

  final String url;

  @override
  State<_BrowserLikeCameraView> createState() => _BrowserLikeCameraViewState();
}

class _BrowserLikeCameraViewState extends State<_BrowserLikeCameraView> {
  late final WebViewController _controller;

  String _html(String src) =>
      '''
<!doctype html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <style>
      html, body { height: 100%; margin: 0; background: #000; }
      #wrap { display: flex; align-items: center; justify-content: center; height: 100%; }
      img { width: 100%; height: 100%; object-fit: contain; }
    </style>
  </head>
  <body>
    <div id="wrap">
      <img src="$src" alt="camera" />
    </div>
  </body>
 </html>
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..loadHtmlString(_html(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}

class _MjpegStream extends StatefulWidget {
  const _MjpegStream({required this.streamUrl});

  final String streamUrl;

  @override
  State<_MjpegStream> createState() => _MjpegStreamState();
}

class _MjpegStreamState extends State<_MjpegStream> {
  Uint8List? _frame;
  Object? _error;
  bool _loading = true;
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;
  List<int>? _boundaryBytes;
  List<int> _buffer = <int>[];
  Object? _lastConnectionError;

  @override
  void initState() {
    super.initState();
    _startStream();
  }

  @override
  void didUpdateWidget(_MjpegStream oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      _restartStream();
    }
  }

  Future<void> _restartStream() async {
    await _stopStream();
    await _startStream();
  }

  Future<void> _startStream() async {
    await _stopStream();
    setState(() {
      _loading = true;
      _error = null;
      _frame = null;
    });

    _lastConnectionError = null;
    final candidates = _streamCandidates(widget.streamUrl);

    for (final candidate in candidates) {
      final connected = await _openStream(candidate);
      if (!mounted) return;

      if (connected) {
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _error =
          _lastConnectionError ??
          Exception('Unable to establish camera stream.');
      _loading = false;
    });
  }

  Future<void> _stopStream() async {
    await _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
    _buffer = <int>[];
    _boundaryBytes = null;
  }

  @override
  void dispose() {
    _stopStream();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _LiveFeedError(message: _error.toString());
    }
    if (_frame != null) {
      return Image.memory(_frame!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  String? _extractBoundary(String? contentType) {
    if (contentType == null) return null;
    final segments = contentType.split(';');
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.toLowerCase().startsWith('boundary=')) {
        return trimmed.substring('boundary='.length).trim();
      }
    }
    return null;
  }

  List<int> _buildBoundary(String boundary) => ascii.encode('--$boundary');

  Future<bool> _openStream(String urlString) async {
    http.Client? candidateClient;
    try {
      final uri = Uri.parse(urlString);
      candidateClient = http.Client();

      final request = http.Request('GET', uri)
        ..headers['Accept'] = 'multipart/x-mixed-replace';

      final response = await candidateClient
          .send(request)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              candidateClient?.close();
              throw TimeoutException(
                'Camera stream connection timed out after 5 seconds',
              );
            },
          );

      if (response.statusCode >= 400) {
        throw Exception('Camera responded with HTTP ${response.statusCode}');
      }

      var boundary = _extractBoundary(response.headers['content-type']);

      // Fallback: if no boundary in headers, try common JPEG start marker
      boundary ??= 'BOUNDARY'; // Dummy boundary for raw JPEG stream detection

      _client = candidateClient;
      candidateClient = null;
      _boundaryBytes = _buildBoundary(boundary);
      _buffer = <int>[];

      _subscription = response.stream.listen(
        (chunk) {
          if (_buffer.length > 5 * 1024 * 1024) {
            // Prevent unbounded memory growth; keep only recent data
            _buffer = _buffer.sublist(_buffer.length - 1024 * 1024);
          }
          _buffer.addAll(chunk);
          _consumeFrames();
        },
        onError: (error, stackTrace) {
          if (!mounted) return;
          setState(() {
            _error = error;
            _loading = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _loading = false;
          });
        },
        cancelOnError: true,
      );

      _lastConnectionError = null;
      return true;
    } catch (error) {
      candidateClient?.close();
      _lastConnectionError = error;
      return false;
    }
  }

  List<String> _streamCandidates(String rawUrl) {
    final candidates = <String>[];
    final seen = <String>{};

    void addCandidate(String? url) {
      final normalized = BabyMonitorReadings._normalizeHttpUrl(url);
      if (normalized == null) return;
      if (seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    final normalized = BabyMonitorReadings._normalizeHttpUrl(rawUrl);
    if (normalized == null) {
      addCandidate(rawUrl);
      return candidates;
    }

    final baseUri = Uri.parse(normalized);

    // Priority 1: Exact URL provided
    addCandidate(rawUrl);

    // Priority 2: Root endpoint (e.g., http://192.168.0.106/)
    addCandidate(baseUri.replace(path: '/', query: '').toString());

    // Priority 3: /stream endpoint (common ESP32 default)
    if (!normalized.toLowerCase().contains('/stream')) {
      addCandidate(baseUri.replace(path: '/stream', query: '').toString());
    }

    // Priority 4: Port 81 with root
    addCandidate(baseUri.replace(port: 81, path: '/', query: '').toString());

    // Priority 5: Port 81 with /stream
    if (!normalized.toLowerCase().contains('/stream')) {
      addCandidate(
        baseUri.replace(port: 81, path: '/stream', query: '').toString(),
      );
    }

    return candidates;
  }

  void _consumeFrames() {
    final boundaryBytes = _boundaryBytes;
    if (boundaryBytes == null || boundaryBytes.isEmpty) {
      return;
    }

    // JPEG start marker (FFD8FF)
    const List<int> jpegStart = <int>[0xFF, 0xD8, 0xFF];
    // JPEG end marker (FFD9)
    const List<int> jpegEnd = <int>[0xFF, 0xD9];

    while (true) {
      // Try to find a complete JPEG frame
      var jpegStartIndex = _indexOfSequence(_buffer, jpegStart);
      if (jpegStartIndex < 0) {
        // No JPEG start marker found, keep recent data
        if (_buffer.length > 100 * 1024) {
          _buffer = _buffer.sublist(_buffer.length - 50 * 1024);
        }
        break;
      }

      // Look for JPEG end marker after start
      var jpegEndIndex = _indexOfSequence(
        _buffer,
        jpegEnd,
        start: jpegStartIndex + jpegStart.length,
      );
      if (jpegEndIndex < 0) {
        // No end marker yet, need more data
        break;
      }

      // Extract complete JPEG (including end marker)
      final frameEnd = jpegEndIndex + jpegEnd.length;
      try {
        final frame = Uint8List.fromList(
          _buffer.sublist(jpegStartIndex, frameEnd),
        );
        if (mounted && frame.isNotEmpty) {
          setState(() {
            _frame = frame;
            _loading = false;
          });
        }
      } catch (e) {
        // Frame extraction failed, skip
      }

      // Continue searching after this frame
      _buffer = _buffer.sublist(frameEnd);
    }
  }

  int _indexOfSequence(List<int> data, List<int> pattern, {int start = 0}) {
    final max = data.length - pattern.length;
    for (var i = start; i <= max; i++) {
      var matched = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return i;
      }
    }
    return -1;
  }
}

class SensorGrid extends StatelessWidget {
  const SensorGrid({super.key, required this.readings});

  final BabyMonitorReadings readings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 640;
        final double itemWidth;
        if (isWide) {
          itemWidth = (constraints.maxWidth - 16) / 2;
        } else {
          itemWidth = constraints.maxWidth;
        }

        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: itemWidth,
              child: SensorMetricCard(
                icon: Icons.thermostat_rounded,
                label: 'Temperature',
                value: readings.temperatureCelsius,
                chipLabel: readings.temperatureTrend,
                accentColor: _temperatureColor(readings.temperature),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: SensorMetricCard(
                icon: Icons.water_drop_rounded,
                label: 'Humidity',
                value: readings.humidityPercent,
                chipLabel: readings.humidityTrend,
                accentColor: _humidityColor(readings.humidity),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: SensorMetricCard(
                icon: Icons.surround_sound_rounded,
                label: 'Sound Level',
                value: readings.soundDecibels,
                chipLabel: readings.soundTrend,
                accentColor: _soundColor(
                  readings.soundLevel,
                  readings.soundAlert,
                ),
              ),
            ),
            SizedBox(
              width: itemWidth,
              child: SensorMetricCard(
                icon: Icons.motion_photos_on_rounded,
                label: 'Motion Sensor',
                value: readings.motionDetected == null
                    ? '--'
                    : readings.motionDetected!
                    ? 'Detected'
                    : 'None',
                chipLabel: readings.motionDetected == null
                    ? null
                    : readings.motionDetected!
                    ? 'Active'
                    : 'Inactive',
                accentColor: readings.motionDetected == true
                    ? const Color(0xFFE94255)
                    : const Color(0xFF3CC687),
              ),
            ),
          ],
        );
      },
    );
  }
}

class SensorMetricCard extends StatelessWidget {
  const SensorMetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.chipLabel,
    required this.accentColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? chipLabel;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: _withOpacityFactor(accentColor, 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: accentColor),
            ),
            const SizedBox(height: 18),
            Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                value,
                key: ValueKey(value),
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (chipLabel != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _withOpacityFactor(accentColor, 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  chipLabel!,
                  style: textTheme.labelMedium?.copyWith(
                    color: accentColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MotionStatusCard extends StatelessWidget {
  const MotionStatusCard({
    super.key,
    required this.isMotionDetected,
    required this.isDeviceOnline,
    required this.lastUpdated,
  });

  final bool? isMotionDetected;
  final bool? isDeviceOnline;
  final DateTime? lastUpdated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool online = isDeviceOnline ?? false;
    final bool? motion = online ? isMotionDetected : null;
    final bool alert = motion ?? false;
    final Color baseColor = !online
        ? theme.colorScheme.outline
        : alert
        ? const Color(0xFFE94255)
        : const Color(0xFF3CC687);

    final IconData icon = !online
        ? Icons.power_settings_new_rounded
        : alert
        ? Icons.warning_rounded
        : Icons.check_circle_rounded;

    final String label = !online
        ? 'Monitor offline'
        : alert
        ? 'Motion detected'
        : 'Baby is calm';

    final String subtitle = !online
        ? 'Check the monitor power and Wi-Fi connection.'
        : _formatRelativeTime(lastUpdated);

    return Card(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _withOpacityFactor(baseColor, 0.12),
              _withOpacityFactor(baseColor, 0.06),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _withOpacityFactor(baseColor, 0.14)),
        ),
        child: Row(
          children: [
            Container(
              height: 52,
              width: 52,
              decoration: BoxDecoration(
                color: _withOpacityFactor(baseColor, 0.18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: baseColor, size: 30),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_right_rounded),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.data_object_rounded,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No data yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start streaming data from Firebase Realtime Database to see the live feed and sensors.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 52,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 18),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BabyMonitorReadings {
  const BabyMonitorReadings({
    this.liveFeedUrl,
    this.cameraIp,
    this.deviceIp,
    this.isOnline,
    this.soundLevel,
    this.soundAlert,
    this.humidity,
    this.temperature,
    this.motionDetected,
    required this.receivedAt,
  });

  final String? liveFeedUrl;
  final String? cameraIp;
  final String? deviceIp;
  final bool? isOnline;
  final double? soundLevel;
  final bool? soundAlert;
  final double? humidity;
  final double? temperature;
  final bool? motionDetected;
  final DateTime receivedAt;

  DateTime get lastUpdated => receivedAt;

  String get temperatureCelsius =>
      temperature != null ? '${temperature!.toStringAsFixed(1)} °C' : '-- °C';

  String get humidityPercent =>
      humidity != null ? '${humidity!.toStringAsFixed(1)} %' : '-- %';

  String get soundDecibels =>
      soundLevel != null ? '${soundLevel!.toStringAsFixed(0)} dB' : '-- dB';

  String? get temperatureTrend {
    if (temperature == null) return null;
    if (temperature! >= 28) return 'High';
    if (temperature! >= 20) return 'Medium';
    return 'Cold';
  }

  String? get humidityTrend =>
      _trendLabel(humidity, targetLow: 40, targetHigh: 60);
  String? get soundTrend {
    if (soundAlert == true) return 'Alert';
    final level = soundLevel;
    if (level == null) return null;
    if (level >= 70) return 'Loud';
    if (level <= 35) return 'Quiet';
    return 'Comfortable';
  }

  factory BabyMonitorReadings.fromSnapshot(
    DataSnapshot snapshot, {
    required DateTime receivedAt,
  }) {
    final value = snapshot.value;
    if (value is! Map) {
      return BabyMonitorReadings(receivedAt: receivedAt);
    }

    final rootMap = Map<String, dynamic>.from(value);
    final monitorNode = rootMap['baby_monitor'];
    final monitorMap = monitorNode is Map
        ? Map<String, dynamic>.from(monitorNode)
        : rootMap;

    final statusNode = monitorMap['status'];
    final statusMap = statusNode is Map
        ? Map<String, dynamic>.from(statusNode)
        : const <String, dynamic>{};

    final readingsNode = monitorMap['readings'];
    Map<String, dynamic>? readingsMap;
    if (readingsNode is Map) {
      readingsMap = Map<String, dynamic>.from(readingsNode);
    }

    // Get the latest reading which now includes motion and sound events
    final latestReading = _latestSensorSnapshot(readingsMap);

    Map<String, dynamic>? legacySensors;
    if (monitorMap['sensors'] is Map) {
      legacySensors = Map<String, dynamic>.from(monitorMap['sensors']);
    }

    final temperature =
        _asDouble(latestReading?['temperatureC']) ??
        _asDouble(statusMap['temperatureC']) ??
        _asDouble(legacySensors?['temperature']);

    final humidity =
        _asDouble(latestReading?['humidityPct']) ??
        _asDouble(statusMap['humidityPct']) ??
        _asDouble(legacySensors?['humidity']);

    final soundLevel =
        _asDouble(latestReading?['soundLevel']) ??
        _asDouble(statusMap['lastSoundLevel']) ??
        _asDouble(legacySensors?['sound']);

    final bool? soundAlert =
        _asBool(latestReading?['soundThresholdExceeded']) ??
        _asBool(statusMap['soundThresholdExceeded']) ??
        _asBool(legacySensors?['soundThresholdExceeded']);

    // Check for motion in readings with type "motion" or direct motion fields
    bool? motionDetected;

    // First check if latest reading has motion type
    if (latestReading != null) {
      final readingType = _asString(latestReading['type']);
      if (readingType == 'motion') {
        motionDetected = true;
      } else if (readingType == 'sound') {
        // This is a sound event, motion might be in previous reading
        motionDetected = _findLatestMotionInReadings(readingsMap);
      } else {
        // Regular sensor reading, check motionActive field
        motionDetected = _asBool(latestReading['motionActive']);
      }
    }

    // Fallback to status if not found in readings
    motionDetected ??=
        _asBool(statusMap['motionActive']) ??
        _asBool(statusMap['motionDetected']) ??
        _asBool(legacySensors?['motion']) ??
        _asBool(monitorMap['motion']);

    final bool? online = _asBool(statusMap['online']);
    final String? deviceIp = _asString(statusMap['ip']);

    final cameraNode = rootMap['esp32cam'];
    final cameraMap = cameraNode is Map
        ? Map<String, dynamic>.from(cameraNode)
        : const <String, dynamic>{};
    final cameraIp = _asString(cameraMap['ip']);
    final cameraUrl = _asString(cameraMap['url']);
    final streamPath = _asString(cameraMap['streamPath']);
    final liveFeedUrl = _composeCameraStreamUrl(
      primaryUrl: cameraUrl,
      ipAddress: cameraIp,
      streamPath: streamPath,
    );

    return BabyMonitorReadings(
      liveFeedUrl: liveFeedUrl,
      cameraIp: cameraIp,
      deviceIp: deviceIp,
      isOnline: online,
      soundLevel: soundLevel,
      soundAlert: soundAlert,
      humidity: humidity,
      temperature: temperature,
      motionDetected: motionDetected,
      receivedAt: receivedAt,
    );
  }

  static String? _composeCameraStreamUrl({
    String? primaryUrl,
    String? ipAddress,
    String? streamPath,
  }) {
    final normalizedPrimary = _normalizeHttpUrl(primaryUrl);
    final normalizedStreamPath = _normalizeStreamPath(streamPath);

    if (normalizedPrimary != null) {
      return normalizedStreamPath != null
          ? _joinUrlPath(normalizedPrimary, normalizedStreamPath)
          : normalizedPrimary;
    }

    final normalizedHost = _normalizeHttpUrl(ipAddress);
    if (normalizedHost == null) {
      return null;
    }

    if (normalizedStreamPath != null) {
      return normalizedStreamPath.isEmpty
          ? normalizedHost
          : _joinUrlPath(normalizedHost, normalizedStreamPath);
    }

    return normalizedHost;
  }

  static String? _normalizeHttpUrl(String? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final candidate = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final parsed = Uri.tryParse(candidate);
    if (parsed == null || parsed.host.isEmpty) {
      return null;
    }

    final scheme = parsed.scheme.isEmpty ? 'http' : parsed.scheme;
    return parsed.replace(scheme: scheme).toString();
  }

  static String? _normalizeStreamPath(String? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    return trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  }

  static String _joinUrlPath(String base, String path) {
    if (path.isEmpty) {
      return base;
    }

    final baseHasSlash = base.endsWith('/');
    final pathHasSlash = path.startsWith('/');

    if (baseHasSlash && pathHasSlash) {
      return '${base.substring(0, base.length - 1)}$path';
    }

    if (!baseHasSlash && !pathHasSlash) {
      return '$base/$path';
    }

    return '$base$path';
  }

  static Map<String, dynamic>? _latestSensorSnapshot(
    Map<String, dynamic>? readings,
  ) {
    if (readings == null || readings.isEmpty) {
      return null;
    }

    Map<String, dynamic>? latest;
    num latestTimestamp = -1;
    readings.forEach((_, value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        final num? timestamp = _asNum(map['timestampMs']);
        final current = timestamp ?? -1;
        if (current >= latestTimestamp) {
          latestTimestamp = current;
          latest = map;
        }
      }
    });
    return latest;
  }

  static bool? _findLatestMotionInReadings(Map<String, dynamic>? readings) {
    if (readings == null || readings.isEmpty) {
      return null;
    }

    // Look through all readings for motion events
    Map<String, dynamic>? latestMotionReading;
    num latestMotionTimestamp = -1;

    readings.forEach((_, value) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        final readingType = _asString(map['type']);

        // Check if this is a motion event
        if (readingType == 'motion') {
          final num? timestamp = _asNum(map['timestampMs']);
          final current = timestamp ?? -1;
          if (current >= latestMotionTimestamp) {
            latestMotionTimestamp = current;
            latestMotionReading = map;
          }
        }
      }
    });

    // If we found a recent motion event (within last 10 seconds), return true
    if (latestMotionReading != null && latestMotionTimestamp > 0) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - latestMotionTimestamp;
      // Consider motion active if event is less than 10 seconds old
      return age < 10000;
    }

    return null;
  }

  static String? _trendLabel(
    double? value, {
    required double targetLow,
    required double targetHigh,
  }) {
    if (value == null) return null;
    if (value < targetLow) return 'Low';
    if (value > targetHigh) return 'High';
    return 'Optimal';
  }

  static num? _asNum(dynamic value) {
    if (value is int) return value;
    if (value is double) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized.isEmpty) return null;
      if (normalized == 'true' ||
          normalized == 'yes' ||
          normalized == 'detected') {
        return true;
      }
      if (normalized == 'false' ||
          normalized == 'no' ||
          normalized == 'clear') {
        return false;
      }
      if (normalized == '1') return true;
      if (normalized == '0') return false;
    }
    return null;
  }

  static String? _asString(dynamic value) {
    if (value == null) return null;
    final str = value.toString().trim();
    return str.isEmpty ? null : str;
  }
}

Color _withOpacityFactor(Color color, double factor) {
  final clampedFactor = factor.clamp(0.0, 1.0);
  final computedAlpha = ((color.a * clampedFactor) * 255).round().clamp(0, 255);
  return color.withAlpha(computedAlpha);
}

Color _temperatureColor(double? value) {
  if (value == null) {
    return const Color(0xFF5F7FF5);
  }
  if (value < 20) return const Color(0xFF4D9FE3); // Cold - Blue
  if (value >= 28) return const Color(0xFFE75A7C); // High - Red
  return const Color(0xFFFFA54A); // Medium - Orange
}

Color _humidityColor(double? value) {
  if (value == null) {
    return const Color(0xFF5F7FF5);
  }
  if (value < 35) return const Color(0xFF6AA6F8);
  if (value > 65) return const Color(0xFF6B5AEF);
  return const Color(0xFF3CC687);
}

Color _soundColor(double? value, bool? isAlert) {
  if (isAlert == true) {
    return const Color(0xFFE94255);
  }
  if (value == null) {
    return const Color(0xFF5F7FF5);
  }
  if (value >= 70) return const Color(0xFFE94255);
  if (value >= 55) return const Color(0xFFFFA54A);
  return const Color(0xFF3CC687);
}

String _formatRelativeTime(DateTime? timestamp) {
  if (timestamp == null) {
    return 'No recent updates';
  }

  final now = DateTime.now();
  final difference = now.difference(timestamp);

  if (difference.inSeconds.abs() < 45) return 'Updated just now';
  if (difference.inMinutes.abs() < 2) return 'Updated a minute ago';
  if (difference.inMinutes.abs() < 60) {
    final minutes = difference.inMinutes.abs();
    return 'Updated $minutes min ago';
  }
  if (difference.inHours.abs() < 2) {
    return 'Updated an hour ago';
  }
  if (difference.inHours.abs() < 24) {
    final hours = difference.inHours.abs();
    return 'Updated $hours hr ago';
  }

  final local = timestamp.toLocal();
  final date =
      '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return 'Last update $date at $time';
}

// Activity Event Model
enum ActivityType { motion, sound, temperature }

class ActivityEvent {
  final ActivityType type;
  final DateTime timestamp;
  final String description;

  ActivityEvent({
    required this.type,
    required this.timestamp,
    required this.description,
  });

  Map<String, dynamic> toJson() => {
        'type': type.index,
        'timestamp': timestamp.toIso8601String(),
        'description': description,
      };

  factory ActivityEvent.fromJson(Map<String, dynamic> json) {
    return ActivityEvent(
      type: ActivityType.values[json['type'] as int],
      timestamp: DateTime.parse(json['timestamp'] as String),
      description: json['description'] as String,
    );
  }

  IconData get icon {
    switch (type) {
      case ActivityType.motion:
        return Icons.directions_walk_rounded;
      case ActivityType.sound:
        return Icons.volume_up_rounded;
      case ActivityType.temperature:
        return Icons.thermostat_rounded;
    }
  }

  Color get color {
    switch (type) {
      case ActivityType.motion:
        return const Color(0xFFE94255);
      case ActivityType.sound:
        return const Color(0xFFFFA54A);
      case ActivityType.temperature:
        return const Color(0xFF6AA6F8);
    }
  }
}

// Daily Activity History Card Widget
class DailyActivityHistoryCard extends StatelessWidget {
  const DailyActivityHistoryCard({
    super.key,
    required this.activities,
  });

  final List<ActivityEvent> activities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: _withOpacityFactor(theme.colorScheme.primary, 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.history_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Today\'s Activity',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${activities.length} events recorded',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (activities.isEmpty) ...[
              const SizedBox(height: 20),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        size: 48,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No events today',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              ...activities.take(10).map((activity) => _ActivityItem(
                    activity: activity,
                  )),
              if (activities.length > 10) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '+${activities.length - 10} more events',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityItem extends StatelessWidget {
  const _ActivityItem({required this.activity});

  final ActivityEvent activity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = _formatActivityTime(activity.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: _withOpacityFactor(activity.color, 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              activity.icon,
              size: 20,
              color: activity.color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatActivityTime(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    }
  }
}

