import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';

// =======================================================================
// ===== MODEL: satu "Cooler" yang sudah dipasangkan (paired) dengan HP =====
// Supaya banyak HP & banyak cooler tidak tumbukan, setiap cooler dikenali
// lewat deviceId unik (dari chip ESP32-nya sendiri), bukan lewat topic
// global. HP hanya bisa kontrol cooler yang sudah eksplisit ditambahkan.
// =======================================================================
class Cooler {
  String id; // deviceId unik dari firmware, mis. "A1B2C3"
  String nickname; // nama custom dari user, mis. "Cooler Kamar"
  String mode; // "WiFi" (MQTT) atau "Bluetooth" (BLE)
  String? bleRemoteId; // MAC BLE, hanya diisi kalau mode == Bluetooth

  Cooler({required this.id, required this.nickname, required this.mode, this.bleRemoteId});

  Map<String, dynamic> toJson() =>
      {"id": id, "nickname": nickname, "mode": mode, "bleRemoteId": bleRemoteId};

  factory Cooler.fromJson(Map<String, dynamic> j) => Cooler(
        id: j["id"],
        nickname: j["nickname"],
        mode: j["mode"],
        bleRemoteId: j["bleRemoteId"],
      );
}

const String kAppVersion = "1.3.0";

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Mod And TroubleShoot',
      theme: ThemeData.dark(),
      home: SplashScreen(),
    );
  }
}

// =======================================================================
// ===== SPLASH SCREEN — ANIMASI PEMBUKA BERGAYA GAMING (MLBB/FF STYLE) ===
// =======================================================================
class _SplashParticle {
  final double x; // posisi horizontal awal (0..1)
  final double speed; // faktor kecepatan naik
  final double size; // ukuran partikel
  final double phase; // offset siklus awal (0..1)
  final double drift; // amplitudo goyangan horizontal

  _SplashParticle({
    required this.x,
    required this.speed,
    required this.size,
    required this.phase,
    required this.drift,
  });
}

class SplashScreen extends StatefulWidget {
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  // Controller utama: menjalankan urutan animasi satu-kali selama 5.2 detik.
  late final AnimationController _mainCtrl;
  // Controller loop: partikel, cincin energi, dan efek "shine" berjalan terus-menerus.
  late final AnimationController _loopCtrl;
  late final List<_SplashParticle> _particles;

  @override
  void initState() {
    super.initState();

    final rnd = Random(7);
    _particles = List.generate(42, (i) {
      return _SplashParticle(
        x: rnd.nextDouble(),
        speed: 0.35 + rnd.nextDouble() * 0.9,
        size: 1.2 + rnd.nextDouble() * 2.6,
        phase: rnd.nextDouble(),
        drift: rnd.nextDouble() * 18 - 9,
      );
    });

    _mainCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 15000));
    _loopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 5000))..repeat();

    _mainCtrl.forward();
    _mainCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 400), _goToApp);
      }
    });
  }

  void _goToApp() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (_, anim, __) => ControllerPage(),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 1.06, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _loopCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color neon = Color(0xFF33F0FF);

    return Scaffold(
      backgroundColor: const Color(0xFF03040A),
      body: AnimatedBuilder(
        animation: Listenable.merge([_mainCtrl, _loopCtrl]),
        builder: (context, _) {
          final t = _mainCtrl.value.clamp(0.0, 1.0);
          final loop = _loopCtrl.value;

          double stage(double begin, double end, {Curve curve = Curves.linear}) {
            return curve.transform(Interval(begin, end, curve: Curves.linear).transform(t)).clamp(0.0, 1.0);
          }

          final ringIntro = stage(0.0, 0.45, curve: Curves.easeOutExpo);
          final logoScale = stage(0.05, 0.55, curve: Curves.elasticOut);
          final logoFade = stage(0.0, 0.30);
          final titleT = stage(0.35, 0.70, curve: Curves.easeOutCubic);
          final subtitleT = stage(0.50, 0.80, curve: Curves.easeOutCubic);
          final barT = stage(0.05, 0.97, curve: Curves.easeInOutSine);
          final flashT = stage(0.94, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              // latar gradasi radial gelap ala HUD game
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.1),
                    radius: 1.15,
                    colors: [Color(0xFF0C1B2A), Color(0xFF03040A)],
                  ),
                ),
              ),
              // partikel energi melayang naik
              CustomPaint(
                painter: _ParticlePainter(particles: _particles, loop: loop, color: neon),
                size: Size.infinite,
              ),
              // cincin gelombang energi di belakang logo
              Center(
                child: CustomPaint(
                  painter: _RingPainter(loopValue: loop, intro: ringIntro, color: neon),
                  size: const Size(320, 320),
                ),
              ),
              // bingkai hexagon berputar (efek "circuit")
              Center(
                child: Transform.rotate(
                  angle: loop * 2 * pi,
                  child: Opacity(
                    opacity: (0.28 * ringIntro).clamp(0.0, 0.28),
                    child: CustomPaint(
                      painter: _HexPainter(color: neon),
                      size: const Size(210, 210),
                    ),
                  ),
                ),
              ),
              // konten utama: logo, judul, subjudul, progress bar
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: logoFade,
                      child: Transform.scale(
                        scale: 0.4 + 0.6 * logoScale,
                        child: Container(
                          width: 108,
                          height: 108,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [neon.withOpacity(0.9), Colors.blueAccent.withOpacity(0.6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: neon.withOpacity(0.5 + 0.25 * sin(loop * 2 * pi).abs()),
                                blurRadius: 42,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.ac_unit, color: Colors.white, size: 56),
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Opacity(
                      opacity: titleT,
                      child: Transform.translate(
                        offset: Offset(0, (1 - titleT) * 18),
                        child: ShaderMask(
                          shaderCallback: (bounds) {
                            final sweep = (loop * 2.4) % 2.4 - 0.7;
                            return LinearGradient(
                              colors: const [Colors.white, Color(0xFFBFF7FF), Colors.white],
                              stops: [
                                (sweep - 0.25).clamp(0.0, 1.0),
                                sweep.clamp(0.0, 1.0),
                                (sweep + 0.25).clamp(0.0, 1.0),
                              ],
                            ).createShader(bounds);
                          },
                          child: const Text(
                            'COOLER CONTROLLER',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: subtitleT,
                      child: Text(
                        'GAME-GRADE VOLTAGE ENGINE',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 4,
                          color: neon.withOpacity(0.8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),
                    Opacity(
                      opacity: barT > 0 ? 1 : 0,
                      child: Column(
                        children: [
                          Container(
                            width: 190,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: barT,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    gradient: LinearGradient(colors: [neon, Colors.blueAccent]),
                                    boxShadow: [BoxShadow(color: neon.withOpacity(0.7), blurRadius: 8)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'LOADING ${(barT * 100).toInt()}%',
                            style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // versi aplikasi di bagian bawah
              Positioned(
                bottom: 26,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: subtitleT,
                  child: Center(
                    child: Text(
                      'v$kAppVersion',
                      style: const TextStyle(color: Colors.white30, fontSize: 12, letterSpacing: 1),
                    ),
                  ),
                ),
              ),
              // kilatan putih halus saat transisi keluar dari splash
              if (flashT > 0)
                IgnorePointer(
                  child: Opacity(
                    opacity: (flashT * 0.85).clamp(0.0, 0.85),
                    child: Container(color: Colors.white),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_SplashParticle> particles;
  final double loop;
  final Color color;
  _ParticlePainter({required this.particles, required this.loop, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      final progress = (loop + p.phase) % 1.0;
      final y = size.height * (1 - progress);
      final x = p.x * size.width + sin((progress + p.phase) * 2 * pi) * p.drift;
      final opacity = sin(progress * pi).clamp(0.0, 1.0);
      paint.color = color.withOpacity(0.55 * opacity);
      canvas.drawCircle(Offset(x, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}

class _RingPainter extends CustomPainter {
  final double loopValue;
  final double intro;
  final Color color;
  _RingPainter({required this.loopValue, required this.intro, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    for (int i = 0; i < 3; i++) {
      final progress = (loopValue + i / 3) % 1.0;
      final radius = maxRadius * progress * intro;
      final opacity = ((1 - progress) * 0.5 * intro).clamp(0.0, 0.5);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withOpacity(opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => true;
}

class _HexPainter extends CustomPainter {
  final Color color;
  _HexPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 3) * i - pi / 2;
      final point = Offset(center.dx + radius * cos(angle), center.dy + radius * sin(angle));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) => false;
}

// =======================================================================
// ===== RADAR / PENTAGON CHART — menggambar 5 metrik LIVE dari HP =======
// Nilai (0-100) datang dari _ControllerPageState (baterai, jaringan,
// refresh rate, performa render, respons sentuh) yang semuanya diambil
// dari API sistem Flutter asli, bukan angka dummy.
// =======================================================================
class _RadarChartPainter extends CustomPainter {
  final List<double> values; // 0..100, searah jarum jam mulai dari atas
  final List<String> labels;
  final Color color;

  _RadarChartPainter({required this.values, required this.labels, required this.color});

  Offset _pointFor(Offset center, double radius, int i, int sides, double fraction) {
    final angle = -pi / 2 + i * (2 * pi / sides);
    return Offset(
      center.dx + radius * fraction * cos(angle),
      center.dy + radius * fraction * sin(angle),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2 - 6);
    final radius = min(size.width, size.height) / 2 - 34;
    final sides = values.length;
    if (sides < 3) return;

    final gridPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Cincin grid 25/50/75/100%
    for (final f in [0.25, 0.5, 0.75, 1.0]) {
      final path = Path();
      for (int i = 0; i < sides; i++) {
        final p = _pointFor(center, radius, i, sides, f);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, gridPaint);
    }

    // Garis sumbu dari tengah ke tiap sudut
    for (int i = 0; i < sides; i++) {
      canvas.drawLine(center, _pointFor(center, radius, i, sides, 1.0), gridPaint);
    }

    // Poligon nilai live
    final valuePath = Path();
    for (int i = 0; i < sides; i++) {
      final f = (values[i] / 100).clamp(0.0, 1.0);
      final p = _pointFor(center, radius, i, sides, f);
      if (i == 0) {
        valuePath.moveTo(p.dx, p.dy);
      } else {
        valuePath.lineTo(p.dx, p.dy);
      }
    }
    valuePath.close();

    canvas.drawPath(valuePath, Paint()..color = color.withOpacity(0.28)..style = PaintingStyle.fill);
    canvas.drawPath(
      valuePath,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );

    for (int i = 0; i < sides; i++) {
      final f = (values[i] / 100).clamp(0.0, 1.0);
      final p = _pointFor(center, radius, i, sides, f);
      canvas.drawCircle(p, 3.5, Paint()..color = color);
    }

    // Label tiap sumbu
    for (int i = 0; i < sides; i++) {
      final p = _pointFor(center, radius, i, sides, 1.28);
      final tp = TextPainter(
        text: TextSpan(text: labels[i], style: const TextStyle(color: Colors.white70, fontSize: 10)),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: 74);
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _RadarChartPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class ControllerPage extends StatefulWidget {
  @override
  _ControllerPageState createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  // ===== DAFTAR COOLER YANG SUDAH DIPASANGKAN (persist ke HP) =====
  // Ini kuncinya supaya tidak tumbukan: app hanya mau ngirim perintah ke
  // cooler yang eksplisit ada di daftar ini (dikenali dari deviceId unik).
  List<Cooler> pairedCoolers = [];
  Cooler? activeCooler;

  // Getter kompatibilitas dengan kode lama yang masih pakai "connectionMode"
  String get connectionMode => activeCooler?.mode ?? "WiFi";

  // ===== TEMA WARNA (custom) =====
  Color accentColor = Colors.cyanAccent;
  final List<Color> colorPalette = [
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.pinkAccent,
    Colors.blueAccent,
    Colors.amberAccent,
    Colors.tealAccent,
    Colors.redAccent,
    Colors.lightGreenAccent,
  ];

  // ===== MQTT =====
  MqttServerClient? mqttClient;
  final String broker = "broker.emqx.io";
  // Topic sekarang per-cooler (pakai deviceId), BUKAN global lagi.
  // Ini kunci supaya HP A tidak bisa mengontrol Cooler B secara tidak sengaja.
  String get cmdTopic => "cooler/${activeCooler?.id}/command";
  String get statusTopic => "cooler/${activeCooler?.id}/status";

  // ===== BLUETOOTH =====
  BluetoothDevice? bleDevice;
  bool isScanning = false;
  List<ScanResult> scanResults = [];
  bool bleConnected = false;

  // ===== DATA VOLTASE =====
  // Hardware (board decoy PD3.1/QC3.0) mendukung 4 level tegangan
  // tetap secara fisik: 5V / 9V / 12V / 15V. Tidak ada mode kontinu.
  double setVolt = 5.0; // voltase yang sedang aktif/terkirim
  String ledMode = "off"; // "off" | "static" | "running" | "disco" | "bounce"
  String lastLedEffect = "running"; // efek terakhir dipilih, dipakai saat tombol ON
  String uptime = "00:00:00";
  String status = "🔴 Offline";

  // ===== WIFI SETUP =====
  List<Map<String, dynamic>> wifiList = [];
  bool isScanningWifi = false;
  String selectedSSID = "";
  TextEditingController passwordController = TextEditingController();

  // =======================================================================
  // ===== METRIK SISTEM LIVE UNTUK RADAR CHART (data asli HP, real-time) ==
  // Semua nilai di sini diambil langsung dari sensor/API sistem Flutter,
  // BUKAN angka dummy. Kalau sumber datanya belum siap, nilainya 0/default
  // sampai data asli pertama masuk.
  // =======================================================================
  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<BatteryState>? _batteryStateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _batteryPollTimer;
  Timer? _metricsUiTimer;

  double liveRefreshRate = 60.0; // Hz asli layar HP (bisa berubah kalau adaptive refresh rate)
  int liveBatteryPercent = 0; // % baterai HP asli
  List<ConnectivityResult> liveConnectivity = [ConnectivityResult.none];
  final List<int> _frameSpansUs = []; // rolling window durasi tiap frame asli (mikrodetik)
  double liveFps = 0; // fps aktual hasil hitung dari frame timing asli
  double livePerformanceScore = 0; // 0-100, dari fps aktual dibanding refresh rate layar
  double liveTouchScore = 0; // 0-100, dari rasio frame yang tidak jank (real, bukan simulasi)

  double get liveNetworkScore {
    if (liveConnectivity.contains(ConnectivityResult.wifi) ||
        liveConnectivity.contains(ConnectivityResult.ethernet)) return 100;
    if (liveConnectivity.contains(ConnectivityResult.vpn)) return 80;
    if (liveConnectivity.contains(ConnectivityResult.mobile)) return 65;
    if (liveConnectivity.contains(ConnectivityResult.bluetooth)) return 30;
    return 0;
  }

  String get liveNetworkLabel {
    if (liveConnectivity.contains(ConnectivityResult.wifi)) return "WiFi";
    if (liveConnectivity.contains(ConnectivityResult.ethernet)) return "Ethernet";
    if (liveConnectivity.contains(ConnectivityResult.vpn)) return "VPN";
    if (liveConnectivity.contains(ConnectivityResult.mobile)) return "Data Seluler";
    if (liveConnectivity.contains(ConnectivityResult.bluetooth)) return "Bluetooth";
    return "Offline";
  }

  @override
  void initState() {
    super.initState();
    _initApp();
    _initSystemMetrics();
  }

  void _initSystemMetrics() {
    // Refresh rate layar sebenarnya — butuh 1 frame render dulu supaya context siap
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final display = View.of(context).display;
      setState(() => liveRefreshRate = display.refreshRate);
    });

    // Baterai HP asli. battery_plus tidak punya stream level langsung,
    // jadi di-poll berkala + setiap ada perubahan status cas/tidak cas.
    _battery.batteryLevel.then((v) {
      if (mounted) setState(() => liveBatteryPercent = v);
    });
    _batteryPollTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final v = await _battery.batteryLevel;
      if (mounted) setState(() => liveBatteryPercent = v);
    });
    _batteryStateSub = _battery.onBatteryStateChanged.listen((_) async {
      final v = await _battery.batteryLevel;
      if (mounted) setState(() => liveBatteryPercent = v);
    });

    // Jenis koneksi jaringan HP asli (WiFi / data seluler / offline)
    _connectivity.checkConnectivity().then((r) {
      if (mounted) setState(() => liveConnectivity = r);
    });
    _connectivitySub = _connectivity.onConnectivityChanged.listen((r) {
      if (mounted) setState(() => liveConnectivity = r);
    });

    // Performa render & respons sentuh — dihitung dari timing frame asli
    // yang dilaporkan Flutter engine, bukan angka rekaan.
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _metricsUiTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (mounted) setState(() {}); // update tampilan radar dari data yang sudah terkumpul
    });
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frameSpansUs.add(t.totalSpan.inMicroseconds);
      if (_frameSpansUs.length > 90) _frameSpansUs.removeAt(0);
    }
    if (_frameSpansUs.isEmpty) return;

    final avgUs = _frameSpansUs.reduce((a, b) => a + b) / _frameSpansUs.length;
    liveFps = avgUs > 0 ? 1000000 / avgUs : liveRefreshRate;

    final refTarget = liveRefreshRate > 0 ? liveRefreshRate : 60.0;
    livePerformanceScore = (liveFps / refTarget * 100).clamp(0, 100);

    // Frame dianggap "jank" kalau durasinya > 1.5x target 1 frame di refresh
    // rate saat ini — ini indikator nyata seberapa lancar HP merespons
    // render setelah ada sentuhan/input, diambil dari data frame sungguhan.
    final targetFrameUs = 1000000 / refTarget;
    final smoothCount = _frameSpansUs.where((us) => us <= targetFrameUs * 1.5).length;
    liveTouchScore = (smoothCount / _frameSpansUs.length * 100).clamp(0, 100);
  }

  @override
  void dispose() {
    _batteryPollTimer?.cancel();
    _metricsUiTimer?.cancel();
    _batteryStateSub?.cancel();
    _connectivitySub?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    passwordController.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    // Minta izin Bluetooth & Lokasi dulu (wajib di Android 12+), kalau tidak
    // diminta di sini, scan BLE akan gagal diam-diam.
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    await _loadPairedCoolers();

    if (activeCooler != null) {
      _connectActiveCooler();
    }
  }

  // ===== PENYIMPANAN DAFTAR COOLER (persist antar sesi app) =====
  Future<void> _loadPairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('paired_coolers');
    final lastActiveId = prefs.getString('active_cooler_id');
    if (raw != null) {
      List<dynamic> list = jsonDecode(raw);
      setState(() {
        pairedCoolers = list.map((e) => Cooler.fromJson(e)).toList();
        if (pairedCoolers.isNotEmpty) {
          activeCooler = pairedCoolers.firstWhere(
            (c) => c.id == lastActiveId,
            orElse: () => pairedCoolers.first,
          );
        }
      });
    }
  }

  Future<void> _savePairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'paired_coolers', jsonEncode(pairedCoolers.map((c) => c.toJson()).toList()));
    if (activeCooler != null) {
      await prefs.setString('active_cooler_id', activeCooler!.id);
    }
  }

  // ===== SAMBUNGKAN KE COOLER YANG SEDANG AKTIF =====
  void _connectActiveCooler() {
    if (activeCooler == null) return;
    if (activeCooler!.mode == "WiFi") {
      connectMQTT();
    } else {
      _connectBleById(activeCooler!.bleRemoteId);
    }
  }

  Future<void> _connectBleById(String? remoteId) async {
    if (remoteId == null) return;
    try {
      final device = BluetoothDevice.fromId(remoteId);
      await connectBLE(device);
    } catch (e) {
      _showSnack("⚠️ Gagal konek ulang ke ${activeCooler?.nickname}, coba scan ulang");
    }
  }

  // ===== SWITCH COOLER AKTIF (dipanggil dari drawer) =====
  void switchActiveCooler(Cooler cooler) {
    // Putuskan koneksi cooler sebelumnya dulu supaya tidak nyangkut
    if (activeCooler?.mode == "Bluetooth" && bleDevice != null) {
      bleDevice!.disconnect();
    }
    if (activeCooler?.mode == "WiFi" && _mqttConnected) {
      mqttClient?.disconnect();
    }
    setState(() {
      activeCooler = cooler;
      status = "🔴 Offline";
      bleConnected = false;
    });
    _savePairedCoolers();
    _connectActiveCooler();
  }

  void removeCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id);
      if (activeCooler?.id == cooler.id) {
        activeCooler = pairedCoolers.isNotEmpty ? pairedCoolers.first : null;
        status = "🔴 Offline";
      }
    });
    _savePairedCoolers();
    if (activeCooler != null) _connectActiveCooler();
  }

  void addCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id); // hindari duplikat
      pairedCoolers.add(cooler);
      activeCooler = cooler;
      status = "🔴 Offline";
    });
    _savePairedCoolers();
    _connectActiveCooler();
  }

  // ===== MQTT =====
  void connectMQTT() async {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    // Client ID unik per-cooler per-sesi supaya tidak saling "menendang"
    // koneksi kalau ada beberapa HP nyambung ke broker yang sama.
    final clientId = 'flutter_${activeCooler!.id}_${DateTime.now().millisecondsSinceEpoch}';
    mqttClient = MqttServerClient(broker, clientId);
    mqttClient!.port = 1883;
    mqttClient!.keepAlivePeriod = 20;
    mqttClient!.onConnected = () {
      setState(() => status = "🟢 Online");
      mqttClient!.subscribe(statusTopic, MqttQos.atLeastOnce);
    };
    mqttClient!.onDisconnected = () => setState(() => status = "🔴 Offline");
    mqttClient!.updates!.listen((msgs) {
      final msg = msgs[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      try {
        var data = jsonDecode(payload);
        // Jaga-jaga: pastikan status ini benar dari cooler yang sedang aktif,
        // bukan nyasar dari cooler lain (mis. saat baru switch cooler).
        if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
        setState(() {
          setVolt = (data['setVoltage'] ?? setVolt).toDouble();
          ledMode = data['ledMode'] ?? ledMode;
          uptime = data['uptime'] ?? "00:00:00";
          // Sinkronkan "efek terakhir" dari status device asli, supaya tombol
          // "Nyala" tidak salah kirim efek lama setelah reconnect/restart app.
          if (ledMode != "off") lastLedEffect = ledMode;
        });
      } catch (e) {}
    });
    try {
      await mqttClient!.connect();
    } catch (e) {
      setState(() => status = "🔴 Offline");
    }
  }

  bool get _mqttConnected =>
      mqttClient != null &&
      mqttClient!.connectionStatus!.state == MqttConnectionState.connected;

  void sendCommandMQTT(double volt) async {
    if (!_mqttConnected) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Tidak terhubung ke broker MQTT");
      return;
    }
    var builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"voltage": volt}));
    mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
    setState(() {
      setVolt = volt;
    });
  }

  void sendLedCommandMQTT(String mode) async {
    if (!_mqttConnected) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Tidak terhubung ke broker MQTT");
      return;
    }
    var builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({"ledMode": mode}));
    mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
    setState(() {
      ledMode = mode;
    });
  }

  // ===== BLUETOOTH =====
  void scanBLE() async {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });
    FlutterBluePlus.startScan(timeout: Duration(seconds: 5));
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() {
        // Nama unik per-unit ("ESP32-Cooler-XXXXXX") -> tiap fisik cooler
        // muncul sebagai entri terpisah di daftar, tidak bakal ketuker.
        scanResults =
            results.where((r) => r.device.name.contains("ESP32-Cooler-")).toList();
      });
    });
    await Future.delayed(Duration(seconds: 6));
    setState(() {
      isScanning = false;
    });
  }

  // Ambil ID unik cooler dari nama BLE-nya, mis. "ESP32-Cooler-A1B2C3" -> "A1B2C3"
  String extractDeviceId(String bleName) {
    final parts = bleName.split("ESP32-Cooler-");
    return parts.length > 1 ? parts[1].trim() : bleName;
  }

  Future<void> connectBLE(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        bleDevice = device;
        bleConnected = true;
        status = "🟢 Online";
      });
      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.setNotifyValue(true);
            characteristic.onValueReceived.listen((value) {
              String payload = utf8.decode(value);
              try {
                var data = jsonDecode(payload);
                if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
                setState(() {
                  setVolt = (data['setVoltage'] ?? setVolt).toDouble();
                  ledMode = data['ledMode'] ?? ledMode;
                  uptime = data['uptime'] ?? "00:00:00";
                  if (ledMode != "off") lastLedEffect = ledMode;
                });
              } catch (e) {}
            });
          }
        }
      }
    } catch (e) {
      setState(() {
        bleConnected = false;
        status = "🔴 Offline";
      });
    }
  }

  void sendCommandBLE(double volt) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode({"voltage": volt})));
            setState(() {
              setVolt = volt;
            });
            return;
          }
        }
      }
    } catch (e) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLedCommandBLE(String mode) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode({"ledMode": mode})));
            setState(() {
              ledMode = mode;
            });
            return;
          }
        }
      }
    } catch (e) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLed(String mode) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    if (mode != "off") lastLedEffect = mode; // ingat efek terakhir buat tombol ON
    if (connectionMode == "WiFi") {
      sendLedCommandMQTT(mode);
    } else {
      sendLedCommandBLE(mode);
    }
  }

  void sendVoltage(double volt) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    volt = double.parse(volt.toStringAsFixed(1));
    if (connectionMode == "WiFi") {
      sendCommandMQTT(volt);
    } else {
      sendCommandBLE(volt);
    }
  }

  // ===== WIFI SETUP =====
  Future<void> scanWiFi() async {
    setState(() {
      isScanningWifi = true;
      wifiList.clear();
    });
    try {
      var response =
          await http.get(Uri.parse("http://192.168.4.1/scanwifi")).timeout(Duration(seconds: 5));
      if (response.statusCode == 200) {
        if (response.body.contains("scanning")) {
          await Future.delayed(Duration(seconds: 3));
          await scanWiFi();
          return;
        }
        List<dynamic> data = jsonDecode(response.body);
        setState(() {
          wifiList = data.map((e) => {"ssid": e['ssid'], "rssi": e['rssi']}).toList();
          isScanningWifi = false;
        });
      }
    } catch (e) {
      setState(() {
        isScanningWifi = false;
      });
      _showSnack("⚠️ Pastikan HP terhubung ke ESP32-Config");
    }
  }

  Future<void> connectWiFi(String ssid, String password) async {
    try {
      // Pakai Uri.http(...) dengan Map query parameters supaya ssid/password
      // otomatis di-encode dengan benar (sebelumnya string mentah disambung
      // langsung, jadi rusak kalau ssid/password ada spasi atau karakter
      // spesial seperti & + # %).
      var url = Uri.http("192.168.4.1", "/setwifi", {"ssid": ssid, "password": password});
      var response = await http.get(url);
      if (response.statusCode == 200) {
        _showSnack("✅ ESP32 berhasil terhubung ke $ssid");
        Navigator.pop(context);
        await Future.delayed(Duration(seconds: 5));
        connectMQTT();
      } else {
        _showSnack("❌ Gagal terhubung, coba lagi");
      }
    } catch (e) {
      _showSnack("⚠️ Pastikan HP terhubung ke ESP32-Config");
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ===== CACHE =====
  void clearAppCache() {
    setState(() {
      wifiList.clear();
      scanResults.clear();
      selectedSSID = "";
      passwordController.clear();
    });
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack("🧹 Cache aplikasi berhasil dibersihkan");
  }

  void clearEsp32Cache() {
    if (connectionMode == "WiFi") {
      if (_mqttConnected) {
        var builder = MqttClientPayloadBuilder();
        builder.addString(jsonEncode({"action": "clear_cache"}));
        mqttClient!.publishMessage(cmdTopic, MqttQos.atLeastOnce, builder.payload!);
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    } else {
      if (bleConnected) {
        sendBLERaw({"action": "clear_cache"});
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    }
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> sendBLERaw(Map<String, dynamic> payload) async {
    if (!bleConnected || bleDevice == null) return;
    try {
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            await characteristic.write(utf8.encode(jsonEncode(payload)));
            return;
          }
        }
      }
    } catch (e) {}
  }

  // ===== DIALOG: SETUP WIFI =====
  void showWiFiSetupDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) {
          return AlertDialog(
            backgroundColor: Color(0xFF11161f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.wifi, color: accentColor),
                SizedBox(width: 8),
                Expanded(
                    child: Text("Hubungkan Internet ESP32",
                        style: TextStyle(color: Colors.white, fontSize: 16))),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text("📶 WiFi di sekitar",
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70)),
                      ),
                      IconButton(
                        icon: Icon(Icons.refresh, color: accentColor),
                        onPressed: () => scanWiFi(),
                      ),
                    ],
                  ),
                  Expanded(
                    child: isScanningWifi
                        ? Center(child: CircularProgressIndicator(color: accentColor))
                        : wifiList.isEmpty
                            ? Center(
                                child: Text(
                                    "Tidak ada WiFi ditemukan\nPastikan HP terhubung ke ESP32-Config",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white54)))
                            : ListView.builder(
                                itemCount: wifiList.length,
                                itemBuilder: (ctx, index) {
                                  var wifi = wifiList[index];
                                  bool isSelected = selectedSSID == wifi['ssid'];
                                  return Card(
                                    color: isSelected ? accentColor.withOpacity(0.15) : Colors.grey.shade900,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      side: BorderSide(
                                          color: isSelected ? accentColor : Colors.transparent, width: 1.4),
                                    ),
                                    child: ListTile(
                                      leading: Icon(Icons.wifi, color: accentColor),
                                      title: Text(wifi['ssid'], style: TextStyle(color: Colors.white)),
                                      trailing:
                                          Text("${wifi['rssi']}dBm", style: TextStyle(color: Colors.grey)),
                                      onTap: () {
                                        setStateDialog(() {
                                          selectedSSID = wifi['ssid'];
                                        });
                                      },
                                    ),
                                  );
                                },
                              ),
                  ),
                  if (selectedSSID.isNotEmpty) ...[
                    Divider(color: Colors.white24),
                    TextField(
                      controller: passwordController,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Password WiFi",
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: accentColor)),
                      ),
                      obscureText: true,
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          if (passwordController.text.isNotEmpty) {
                            connectWiFi(selectedSSID, passwordController.text);
                          } else {
                            _showSnack("Masukkan password!");
                          }
                        },
                        child: Text("🔗 Hubungkan"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accentColor,
                          foregroundColor: Colors.black,
                          padding: EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Tutup", style: TextStyle(color: accentColor)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===== DIALOG: ABOUT / CHANGELOG =====
  void showAboutChangelogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.info_outline, color: accentColor),
            SizedBox(width: 8),
            Text("About", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: DefaultTextStyle(
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Cooler Controller App",
                    style: TextStyle(color: accentColor, fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Version: $kAppVersion"),
                Divider(color: Colors.white24, height: 20),
                Text("Developer", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Nama: M.ADY AFRIANSYAH"),
                Text("Telegram Dev: t.me/bujanginm"),
                Text("Group Telegram:"),
                Text("https://t.me/forumdiskusitele/371474"),
                Divider(color: Colors.white24, height: 20),
                Text("Tujuan Aplikasi", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text(
                    "Aplikasi ini dibuat hanya untuk tujuan edukasi/pembelajaran, mengenai cara kerja fan cooler apabila dikontrol menggunakan aplikasi."),
                Divider(color: Colors.white24, height: 20),
                Text("Cara Penggunaan (Dari Awal sampai Selesai)",
                    style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text("A. Persiapan Awal",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "1. Pastikan modul ESP32-C3 sudah terpasang & menyala (lampu indikator hidup).\n"
                    "2. Buka aplikasi ini, lalu izinkan permission Bluetooth & Lokasi saat diminta (wajib supaya fitur scan Bluetooth berfungsi)."),
                SizedBox(height: 8),
                Text("B. Menghubungkan ESP32 ke WiFi Rumah (sekali saja)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "3. Kalau ESP32 belum pernah disetel WiFi, dia otomatis memancarkan hotspot bernama \"ESP32-Config\" (password: 12345678). Sambungkan WiFi HP ke hotspot itu dulu.\n"
                    "4. Di aplikasi, buka menu ☰ (kanan atas / drawer) → \"Setup WiFi ESP32\".\n"
                    "5. Tekan ikon refresh untuk scan WiFi sekitar, pilih nama WiFi rumah dari daftar, masukkan passwordnya, lalu tekan \"🔗 Hubungkan\".\n"
                    "6. Tunggu notifikasi berhasil terhubung. ESP32 akan restart & tersambung ke WiFi rumah, status akan berubah jadi \"🟢 Online\"."),
                SizedBox(height: 8),
                Text("C. Menambahkan Cooler ke Aplikasi",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "7. Buka menu ☰ → \"Tambah Cooler Baru\".\n"
                    "8. Isi nama cooler (bebas, mis. \"Cooler Kamar\").\n"
                    "9. Pilih salah satu cara pairing:\n"
                    "   • Scan Bluetooth: tunggu daftar perangkat muncul, ketuk perangkat yang sesuai.\n"
                    "   • Manual (WiFi): masukkan ID Perangkat (dilihat di layar Setup WiFi ESP32 / serial monitor), lalu tekan \"Tambah\".\n"
                    "10. Cooler yang baru ditambahkan otomatis jadi cooler aktif (bisa dicek/diganti lewat menu ☰ → \"Cooler Saya\")."),
                SizedBox(height: 8),
                Text("D. Mengatur Voltase Kipas",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "11. Pastikan status di atas menunjukkan \"🟢 Online\" (cooler sudah terhubung).\n"
                    "12. Di halaman utama, pilih salah satu preset tegangan: 5V / 9V / 12V / 15V.\n"
                    "13. Tekan tombol \"Pilih\" pada preset yang diinginkan — tombol akan berubah jadi \"Terpilih\" dan kipas akan menyesuaikan tegangan.\n"
                    "14. Selesai — kipas kini berjalan sesuai voltase yang dipilih."),
                SizedBox(height: 8),
                Text("E. Fitur Tambahan (opsional)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "• Ganti warna tema aplikasi lewat menu ☰ → \"Tampilan\".\n"
                    "• \"Bersihkan Cache Aplikasi\" untuk menghapus data scan WiFi/Bluetooth sementara.\n"
                    "• \"Bersihkan Cache Modul ESP32\" untuk kirim perintah reset cache ke ESP32.\n"
                    "• Bisa menambahkan & berpindah antar beberapa cooler lewat menu ☰ → \"Cooler Saya\"."),
                Divider(color: Colors.white24, height: 20),
                Text("Status", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Aplikasi ini FREE dan TIDAK untuk di perjual belikan."),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Tutup", style: TextStyle(color: accentColor)),
          ),
        ],
      ),
    );
  }

  // ===== DIALOG: KONFIRMASI CACHE =====
  void _confirmClear(String title, String message, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: TextStyle(color: Colors.white)),
        content: Text(message, style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Batal", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(backgroundColor: accentColor, foregroundColor: Colors.black),
            child: Text("Ya, Bersihkan"),
          ),
        ],
      ),
    );
  }

  // ===== DRAWER (MENU GARIS 3) =====
  // ===== DIALOG: TAMBAH COOLER BARU =====
  // Dua cara: (1) scan Bluetooth lalu pilih unit fisik yang mau dipasangkan,
  // atau (2) masukkan manual ID cooler (dari layar Setup WiFi ESP32 / serial
  // monitor) untuk dikontrol lewat WiFi/MQTT.
  void showAddCoolerDialog() {
    final nicknameController = TextEditingController();
    final manualIdController = TextEditingController();
    int tab = 0; // 0 = Bluetooth, 1 = Manual (WiFi)
    scanBLE();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: Color(0xFF11161f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text("Tambah Cooler Baru", style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nicknameController,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Nama cooler (mis. Cooler Kamar)",
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      ),
                    ),
                    SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Scan Bluetooth"),
                            selected: tab == 0,
                            onSelected: (_) => setDialogState(() => tab = 0),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Manual (WiFi)"),
                            selected: tab == 1,
                            onSelected: (_) => setDialogState(() => tab = 1),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 14),
                    if (tab == 0) ...[
                      if (isScanning)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: accentColor)),
                            SizedBox(width: 10),
                            Text("Mencari cooler di sekitar...", style: TextStyle(color: Colors.white54)),
                          ]),
                        ),
                      if (!isScanning && scanResults.isEmpty)
                        Text("Tidak ada cooler ditemukan. Pastikan Bluetooth aktif & cooler menyala.",
                            style: TextStyle(color: Colors.white38, fontSize: 12)),
                      ...scanResults.map((r) {
                        final id = extractDeviceId(r.device.name);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.bluetooth, color: accentColor),
                          title: Text(r.device.name, style: TextStyle(color: Colors.white)),
                          subtitle: Text("ID: $id", style: TextStyle(color: Colors.white38, fontSize: 11)),
                          onTap: () async {
                            String nickname =
                                nicknameController.text.trim().isEmpty ? r.device.name : nicknameController.text.trim();
                            Navigator.pop(ctx);
                            final cooler = Cooler(
                                id: id, nickname: nickname, mode: "Bluetooth", bleRemoteId: r.device.remoteId.str);
                            addCooler(cooler);
                            await connectBLE(r.device);
                          },
                        );
                      }).toList(),
                      TextButton.icon(
                        onPressed: () => setDialogState(() => scanBLE()),
                        icon: Icon(Icons.refresh, color: accentColor, size: 18),
                        label: Text("Scan ulang", style: TextStyle(color: accentColor)),
                      ),
                    ] else ...[
                      Text(
                        "Buka menu \"Setup WiFi ESP32\" atau layar konfigurasi cooler (192.168.4.1) untuk melihat ID Perangkat-nya, lalu masukkan di sini.",
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: manualIdController,
                        style: TextStyle(color: Colors.white, letterSpacing: 2),
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: "ID Perangkat (mis. A1B2C3)",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Batal", style: TextStyle(color: Colors.white54)),
              ),
              if (tab == 1)
                TextButton(
                  onPressed: () {
                    final id = manualIdController.text.trim().toUpperCase();
                    if (id.isEmpty) {
                      _showSnack("Masukkan ID Perangkat dulu!");
                      return;
                    }
                    String nickname =
                        nicknameController.text.trim().isEmpty ? "Cooler $id" : nicknameController.text.trim();
                    Navigator.pop(ctx);
                    addCooler(Cooler(id: id, nickname: nickname, mode: "WiFi"));
                  },
                  child: Text("Tambah", style: TextStyle(color: accentColor)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Color(0xFF0d1219),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, 28, 20, 20),
              decoration: BoxDecoration(color: Colors.black26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.ac_unit, color: accentColor, size: 34),
                  SizedBox(height: 10),
                  Text("Cooler Controller",
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 2),
                  Text(
                      activeCooler != null
                          ? "${activeCooler!.nickname} • $status"
                          : status,
                      style: TextStyle(
                          fontSize: 12,
                          color: status == "🟢 Online" ? Colors.greenAccent : Colors.redAccent)),
                ],
              ),
            ),
            _drawerSectionTitle("Cooler Saya"),
            if (pairedCoolers.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  "Belum ada cooler yang ditambahkan. Tambah dulu supaya HP ini tahu cooler mana yang mau dikontrol.",
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ...pairedCoolers.map((cooler) {
              bool selected = activeCooler?.id == cooler.id;
              return ListTile(
                leading: Icon(cooler.mode == "WiFi" ? Icons.wifi : Icons.bluetooth,
                    color: selected ? accentColor : Colors.white70),
                title: Text(cooler.nickname,
                    style: TextStyle(
                        color: Colors.white, fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                subtitle: Text("ID: ${cooler.id} • ${cooler.mode}",
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) Icon(Icons.check_circle, color: accentColor, size: 20),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: Colors.white38, size: 20),
                      onPressed: () {
                        Navigator.pop(context);
                        removeCooler(cooler);
                      },
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (!selected) switchActiveCooler(cooler);
                },
              );
            }).toList(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor),
                  ),
                  icon: Icon(Icons.add),
                  label: Text("Tambah Cooler Baru"),
                  onPressed: () {
                    Navigator.pop(context);
                    showAddCoolerDialog();
                  },
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.settings_ethernet, color: Colors.white70),
              title: Text("Setup WiFi ESP32", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                showWiFiSetupDialog();
              },
            ),
            Divider(color: Colors.white12),
            _drawerSectionTitle("Tampilan"),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: colorPalette.map((c) {
                  bool selected = accentColor.value == c.value;
                  return GestureDetector(
                    onTap: () => setState(() => accentColor = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 3),
                      ),
                      child: selected ? Icon(Icons.check, size: 16, color: Colors.black) : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            SizedBox(height: 16),
            Divider(color: Colors.white12),
            _drawerSectionTitle("Perawatan"),
            ListTile(
              leading: Icon(Icons.cleaning_services, color: Colors.white70),
              title: Text("Bersihkan Cache Aplikasi", style: TextStyle(color: Colors.white)),
              subtitle: Text("Hapus data sementara di aplikasi", style: TextStyle(color: Colors.white38, fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Aplikasi",
                  "Data pencarian WiFi/Bluetooth sementara akan dihapus. Lanjutkan?",
                  clearAppCache),
            ),
            ListTile(
              leading: Icon(Icons.memory, color: Colors.white70),
              title: Text("Bersihkan Cache Modul ESP32", style: TextStyle(color: Colors.white)),
              subtitle:
                  Text("Kirim perintah reset cache ke modul ESP32", style: TextStyle(color: Colors.white38, fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Modul ESP32",
                  "Perintah pembersihan cache akan dikirim ke modul ESP32 melalui koneksi $connectionMode. Lanjutkan?",
                  clearEsp32Cache),
            ),
            Divider(color: Colors.white12),
            _drawerSectionTitle("Lainnya"),
            ListTile(
              leading: Icon(Icons.info_outline, color: Colors.white70),
              title: Text("Tentang", style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                showAboutChangelogDialog(context);
              },
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _drawerSectionTitle(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.bold)),
    );
  }

  // ===== UI UTAMA =====
  @override
  Widget build(BuildContext context) {
    bool online = status == "🟢 Online";
    return Scaffold(
      backgroundColor: Color(0xFF090d14),
      drawer: _buildDrawer(),
      appBar: AppBar(
        backgroundColor: Colors.black54,
        elevation: 0,
        titleSpacing: 4,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.ac_unit, color: accentColor, size: 22),
            SizedBox(width: 8),
            Flexible(
              child: Text(
                activeCooler != null ? activeCooler!.nickname.toUpperCase() : "PILIH COOLER",
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(color: online ? Colors.green.shade800 : Colors.red.shade800),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: online ? Colors.greenAccent : Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(online ? "Online" : "Offline",
                        style: TextStyle(
                            fontSize: 12, color: online ? Colors.greenAccent : Colors.redAccent)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            double maxWidth = constraints.maxWidth > 520 ? 480 : constraints.maxWidth;
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(18),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _modeBanner(),
                      SizedBox(height: 16),
                      _timerCard(),
                      SizedBox(height: 16),
                      _voltageDisplayCard(),
                      SizedBox(height: 16),
                      _systemRadarCard(),
                      SizedBox(height: 20),
                      _sectionLabel("Kontrol Voltase (5V - 15V)"),
                      SizedBox(height: 10),
                      _presetList(),
                      SizedBox(height: 10),
                      _ledToggleCard(),
                      SizedBox(height: 10),
                      _hardwareInfoCard(),
                      SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: _actionBtn('Refresh', Icons.refresh, () {
                              if (activeCooler == null) {
                                _showSnack("⚠️ Pilih atau tambah cooler dulu");
                                return;
                              }
                              _connectActiveCooler();
                            }),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: _actionBtn('Setup WiFi', Icons.wifi, showWiFiSetupDialog),
                          ),
                        ],
                      ),
                      SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(text,
        style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5));
  }

  Widget _modeBanner() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(connectionMode == "WiFi" ? Icons.wifi : Icons.bluetooth, color: accentColor, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text("Mode koneksi: $connectionMode",
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Icon(Icons.menu, color: Colors.white38, size: 16),
        ],
      ),
    );
  }

  Widget _timerCard() {
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer, color: accentColor),
          SizedBox(width: 10),
          Text(uptime, style: TextStyle(fontSize: 26, fontFamily: 'monospace', color: Colors.white)),
        ],
      ),
    );
  }

  Widget _ledToggleCard() {
    Widget modeButton(String mode, String label, IconData icon) {
      bool selected = ledMode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => sendLed(mode),
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: 4),
            padding: EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? accentColor : Colors.black26,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Icon(icon, color: selected ? Colors.black : Colors.white54, size: 18),
                SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        color: selected ? Colors.black : Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text("Lampu RGB", style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
          Row(
            children: [
              modeButton("off", "Mati", Icons.power_settings_new),
              Expanded(
                child: GestureDetector(
                  onTap: () => sendLed(lastLedEffect),
                  child: Container(
                    margin: EdgeInsets.symmetric(horizontal: 4),
                    padding: EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: ledMode != "off" ? accentColor : Colors.black26,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.lightbulb, color: ledMode != "off" ? Colors.black : Colors.white54, size: 18),
                        SizedBox(height: 4),
                        Text("Nyala",
                            style: TextStyle(
                                color: ledMode != "off" ? Colors.black : Colors.white54,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: 4, top: 12, bottom: 8),
            child: Text("Efek", style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Row(
            children: [
              modeButton("static", "Diam", Icons.circle),
              modeButton("running", "Berjalan", Icons.arrow_forward),
              modeButton("disco", "Disko", Icons.celebration),
              modeButton("bounce", "Bolak-Balik", Icons.swap_horiz),
            ],
          ),
        ],
      ),
    );
  }

  Widget _voltageDisplayCard() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 30),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accentColor.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Text('${setVolt.toStringAsFixed(1)}V',
              style: TextStyle(fontSize: 46, fontWeight: FontWeight.bold, color: accentColor)),
          SizedBox(height: 6),
          Text('VOLTASE AKTIF', style: TextStyle(fontSize: 12, color: Colors.grey, letterSpacing: 1.5)),
        ],
      ),
    );
  }

  Widget _presetList() {
    final presets = [
      {"v": 5.0, "c": Colors.orangeAccent},
      {"v": 9.0, "c": Colors.blueAccent},
      {"v": 12.0, "c": Colors.redAccent},
      {"v": 15.0, "c": Colors.purpleAccent},
    ];
    return Column(
      children: presets.map((p) {
        double v = p["v"] as double;
        Color c = p["c"] as Color;
        bool selected = setVolt == v;
        return Container(
          margin: EdgeInsets.only(bottom: 10),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? c : Colors.transparent, width: 1.6),
          ),
          child: Row(
            children: [
              Icon(Icons.bolt, color: c),
              SizedBox(width: 12),
              Expanded(
                child: Text('${v.toStringAsFixed(0)} Volt',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              if (selected)
                Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.check_circle, color: c, size: 20),
                ),
              ElevatedButton(
                onPressed: () => sendVoltage(v),
                style: ElevatedButton.styleFrom(
                  backgroundColor: selected ? c : c.withOpacity(0.15),
                  foregroundColor: selected ? Colors.black : c,
                  elevation: 0,
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(selected ? "Terpilih" : "Pilih"),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _systemRadarCard() {
    final labels = ["Jaringan", "Baterai", "Refresh Rate", "Respons Sentuh", "Performa"];
    final values = <double>[
      liveNetworkScore,
      liveBatteryPercent.toDouble(),
      (liveRefreshRate / 144 * 100).clamp(0, 100),
      liveTouchScore,
      livePerformanceScore,
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          Text("Traffic Data — Live",
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          SizedBox(height: 4),
          Text("Diambil langsung dari sensor & sistem HP penguna",
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          SizedBox(height: 8),
          SizedBox(
            height: 230,
            width: double.infinity,
            child: CustomPaint(
              painter: _RadarChartPainter(values: values, labels: labels, color: accentColor),
            ),
          ),
          SizedBox(height: 6),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _metricChip(liveNetworkLabel, "Jaringan"),
              _metricChip("$liveBatteryPercent%", "Baterai"),
              _metricChip("${liveRefreshRate.toStringAsFixed(0)} Hz", "Refresh Rate"),
              _metricChip(liveFps.toStringAsFixed(0), "FPS Aktual"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(color: accentColor, fontWeight: FontWeight.bold, fontSize: 13)),
        Text(label, style: TextStyle(color: Colors.white38, fontSize: 9)),
      ],
    );
  }

  Widget _hardwareInfoCard() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.white38, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "Modul step-up yang dipakai hanya mendukung 4 level tegangan tetap (5V/9V/12V/15V), jadi pemilihan voltase dilakukan lewat 4 tombol di atas.",
              style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(String label, IconData icon, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black38,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
