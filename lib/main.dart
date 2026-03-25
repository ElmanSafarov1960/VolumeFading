import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:volume_controller/volume_controller.dart' as volume_controller;
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Скрываем системный ползунок громкости при старте
  volume_controller.VolumeController.instance.showSystemUI = false;
  await initializeService();
  runApp(const FadeApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // 1. Ручное создание канала (как работало раньше)
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'volume_fade_manual', // Новый ID, чтобы сбросить кэш
    'Volume Fade Service',
    description: 'Manual channel creation for Xiaomi',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  // 2. Настройка сервиса
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: 'volume_fade_manual', // Тот же ID
      foregroundServiceNotificationId: 888,
      initialNotificationTitle: 'Volume Fading',
      initialNotificationContent: 'Service is active',
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  bool isPaused = false;

  // Функция для остановки музыки через AudioSession
  Future<void> pauseMediaNative() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      if (await session.setActive(true)) {
        await session.setActive(false);
      }
    } catch (e) {
      debugPrint("Pause error: $e");
    }
  }

  service.on('stopService').listen((event) => service.stopSelf());
  service.on('pauseFade').listen((event) => isPaused = true);
  service.on('resumeFade').listen((event) => isPaused = false);

  service.on('startFade').listen((event) async {
    final controller = volume_controller.VolumeController.instance;
    controller.showSystemUI = false;

    final int delayMin = event?['delay'] ?? 0;
    final int fadeMin = event?['fade'] ?? 10;

    double startVol = await controller.getVolume();
    double lastVol = startVol;

    // --- ФАЗА ОЖИДАНИЯ (DELAY) ---
    if (delayMin > 0) {
      for (int i = 0; i < delayMin * 60; i++) {
        while (isPaused)
          await Future.delayed(const Duration(milliseconds: 500));
        await Future.delayed(const Duration(seconds: 1));
        double current = await controller.getVolume();
        if ((current - lastVol).abs() > 0.1) {
          service.invoke('fadeStopped');
          service.stopSelf();
          return;
        }
      }
    }

    // --- ФАЗА ПЛАВНОГО ЗАТУХАНИЯ (FADE) ---
    int smoothSteps = 100;
    if (startVol > 0) {
      double totalFadeSec = fadeMin * 60.0;
      int sumLevels = (smoothSteps * (smoothSteps + 1)) ~/ 2;
      double unitTime = totalFadeSec / sumLevels;

      for (int i = smoothSteps; i >= 0; i--) {
        while (isPaused)
          await Future.delayed(const Duration(milliseconds: 500));

        double currentVol = await controller.getVolume();
        // Проверка вмешательства пользователя
        if ((currentVol - lastVol).abs() > 0.07) {
          service.invoke('fadeStopped');
          service.stopSelf();
          return;
        }

        double nextVol = (i / smoothSteps) * startVol;
        controller.setVolume(nextVol);
        lastVol = nextVol;

        if (i > 0) {
          await Future.delayed(
            Duration(milliseconds: (i * unitTime * 1000).toInt()),
          );
        }
      }
    }

    await pauseMediaNative();
    service.invoke('fadeFinished');
    service.stopSelf();
  });
}

class FadeApp extends StatelessWidget {
  const FadeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: const FadeHomePage(),
  );
}

class FadeHomePage extends StatefulWidget {
  const FadeHomePage({super.key});
  @override
  State<FadeHomePage> createState() => _FadeHomePageState();
}

class _FadeHomePageState extends State<FadeHomePage> {
  double _beforeMin = 0;
  double _fadeMin = 10;
  double _currentVol = 0;
  double _originalVol = 0;
  bool _serviceRunning = false;
  bool _paused = false;
  Timer? _volumeTimer;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _updateVolume();
    _volumeTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) => _updateVolume(),
    );
    volume_controller.VolumeController.instance.showSystemUI = false;

    FlutterBackgroundService().on('fadeFinished').listen((event) {
      if (!mounted) return;
      setState(() {
        _serviceRunning = false;
        _paused = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Fade finished")));
    });

    FlutterBackgroundService().on('fadeStopped').listen((event) {
      if (!mounted) return;
      setState(() {
        _serviceRunning = false;
        _paused = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Stopped by user")));
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _beforeMin = prefs.getDouble('beforeMin') ?? 0;
      _fadeMin = prefs.getDouble('fadeMin') ?? 10;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('beforeMin', _beforeMin);
    await prefs.setDouble('fadeMin', _fadeMin);
  }

  void _setPreset(double delay, double fade) {
    if (_serviceRunning) return;
    setState(() {
      _beforeMin = delay;
      _fadeMin = fade;
    });
  }

  Future<void> _updateVolume() async {
    double v = await volume_controller.VolumeController.instance.getVolume();
    if (mounted) setState(() => _currentVol = v);
  }

  @override
  void dispose() {
    _volumeTimer?.cancel();
    super.dispose();
  }

  void _restoreVolume() {
    volume_controller.VolumeController.instance.setVolume(_originalVol);
  }

  Future<void> _startFade() async {
    if (_serviceRunning) return;
    await _saveSettings();
    _originalVol = _currentVol;
    final service = FlutterBackgroundService();
    await service.startService();
    await Future.delayed(const Duration(milliseconds: 600));
    service.invoke('startFade', {
      'delay': _beforeMin.toInt(),
      'fade': _fadeMin.toInt(),
    });
    setState(() {
      _serviceRunning = true;
      _paused = false;
    });
  }

  void _stopService() {
    FlutterBackgroundService().invoke('stopService');
    setState(() {
      _serviceRunning = false;
      _paused = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage("assets/night_background.jpg"),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(Colors.black54, BlendMode.darken),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 50),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: Column(
                    children: [
                      const Text(
                        "QUICK PRESETS",
                        style: TextStyle(
                          color: Colors.white54,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 15),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _presetBtn("15 min", () => _setPreset(0, 15)),
                          _presetBtn("30 min", () => _setPreset(5, 25)),
                          _presetBtn("1 hour", () => _setPreset(10, 50)),
                        ],
                      ),
                      const SizedBox(height: 40),
                      const Divider(color: Colors.white24),
                      const SizedBox(height: 20),
                      _infoText("Before fade", "${_beforeMin.toInt()} min"),
                      Slider(
                        value: _beforeMin,
                        min: 0,
                        max: 60,
                        activeColor: Colors.yellow,
                        onChanged: _serviceRunning
                            ? null
                            : (v) => setState(() => _beforeMin = v),
                      ),
                      const SizedBox(height: 10),
                      _infoText("Fade duration", "${_fadeMin.toInt()} min"),
                      Slider(
                        value: _fadeMin,
                        min: 10,
                        max: 120,
                        activeColor: Colors.orange,
                        onChanged: _serviceRunning
                            ? null
                            : (v) => setState(() => _fadeMin = v),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        "Vol: ${(_currentVol * 15).round()}/15",
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      if (_serviceRunning)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.circle,
                                color: _paused ? Colors.orange : Colors.green,
                                size: 12,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _paused ? "Paused" : "Working",
                                style: TextStyle(
                                  color: _paused ? Colors.orange : Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 30),
                      _btn(
                        !_serviceRunning
                            ? "START FADE"
                            : (_paused ? "RESUME FADE" : "PAUSE FADE"),
                        !_serviceRunning ? Colors.yellow : Colors.orange,
                        !_serviceRunning
                            ? _startFade
                            : () {
                                if (_paused) {
                                  FlutterBackgroundService().invoke(
                                    'resumeFade',
                                  );
                                } else {
                                  FlutterBackgroundService().invoke(
                                    'pauseFade',
                                  );
                                }
                                setState(() => _paused = !_paused);
                              },
                      ),
                      _btn("RESTORE VOLUME", Colors.blue, _restoreVolume),
                      _btn("STOP SERVICE", Colors.red, _stopService),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetBtn(String label, VoidCallback onTap) => ElevatedButton(
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.white.withOpacity(0.1),
      side: const BorderSide(color: Colors.white38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    onPressed: _serviceRunning ? null : onTap,
    child: Text(label, style: const TextStyle(color: Colors.white)),
  );

  Widget _infoText(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.yellow,
        ),
      ),
    ],
  );

  Widget _btn(String txt, Color col, VoidCallback onPres) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    height: 65,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: col.withOpacity(0.1),
        side: BorderSide(color: col, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
      onPressed: onPres,
      child: Text(
        txt,
        style: TextStyle(color: col, fontWeight: FontWeight.bold, fontSize: 18),
      ),
    ),
  );
}
