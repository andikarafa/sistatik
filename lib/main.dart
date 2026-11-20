import 'dart:async';
import 'dart:math' show Random;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'login_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: await _opsiFirebase());
  runApp(const MonitoringBPSApp());
}

class MonitoringBPSApp extends StatelessWidget {
  const MonitoringBPSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Monitoring BPS Terpadu Live',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF29ABE2),
          primary: const Color(0xFF1E8CC0),
          secondary: const Color(0xFFF58634),
          tertiary: const Color(0xFF6DBE4B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E8CC0),
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF58634),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ==========================================
// CEK SESI LOGIN (TIDAK PERLU LOGIN ULANG)
// ==========================================
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<Widget> _tujuan = _tentukan();

  Future<Widget> _tentukan() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const LoginPage();
    try {
      final d = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = d.data();
      if (data?['is_active'] == false) {
        await FirebaseAuth.instance.signOut();
        return const LoginPage(
            pesan: 'Akun Anda sudah dinonaktifkan. Hubungi admin.');
      }
      final role = data?['role'];
      if (role == 'admin') return const AdminDashboardLivePage();
      if (role == 'pimpinan') return const PimpinanPage();
      if (role == 'kepala_tim') {
        return const PegawaiHomePage(peran: 'kepala_tim');
      }
      if (role == 'pegawai') return const PegawaiHomePage();
    } catch (_) {}
    return const LoginPage();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _tujuan,
      builder: (context, snap) {
        if (snap.hasData) return snap.data!;
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo_bps.png', height: 90),
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ==========================================
// KONSTANTA & FUNGSI BERSAMA
// ==========================================
const Color _biru = Color(0xFF1E8CC0);
const Color _oranye = Color(0xFFF58634);
const Color _hijau = Color(0xFF6DBE4B);

// Lokasi kantor dan radius (meter)
const LatLng _kantor = LatLng(-7.342770634790002, 110.49301316517578);
const double _radiusKantor = 100;

// Siklus kirim lokasi: 10 menit (dalam detik)
const int _siklusDetik = 600;

// Daftar tim (ditampilkan sebagai "Tim <nama>")
const List<String> _daftarTim = [
  'Subbag Umum',
  'Statistik Sosial',
  'Statistik Produksi',
  'Statistik Distribusi',
  'Nerwilis',
  'IPDS',
];

const Map<String, String> _labelPeran = {
  'admin': 'Admin',
  'pimpinan': 'Kepala BPS',
  'kepala_tim': 'Kepala Tim',
  'pegawai': 'Pegawai',
};

double _jarakKeKantor(double lat, double lng) =>
    const Distance().as(LengthUnit.Meter, _kantor, LatLng(lat, lng));

bool _diKantor(Map<String, dynamic> d) {
  final lat = (d['latitude'] as num).toDouble();
  final lng = (d['longitude'] as num).toDouble();
  return _jarakKeKantor(lat, lng) <= _radiusKantor;
}

CollectionReference get _pengajuanCol =>
    FirebaseFirestore.instance.collection('pengajuan_tugas');
CollectionReference get _logCol =>
    FirebaseFirestore.instance.collection('log_keluar');

// true jika pegawai sedang bertugas (live tracking aktif)
final ValueNotifier<bool> _bertugasGlobal = ValueNotifier<bool>(false);

// Slot detik (0-599) tetap per pegawai, supaya tidak mengirim bersamaan
int _slotDetik(String uid) {
  var h = 7;
  for (final c in uid.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % _siklusDetik;
}

// Zona di sekitar batas kantor tempat GPS akurat dipakai (meter)
const double _zonaWaspada = 300;
// Margin agar status tidak bolak-balik di tepi radius (meter)
const double _histeresis = 15;

/// Perkirakan kapan batas kantor dilewati dari dua fix berurutan
/// (interpolasi linear terhadap jarak). Hasil selalu di antara kedua fix.
DateTime _perkirakanLintas({
  required DateTime waktuA,
  required double jarakA,
  required DateTime waktuB,
  required double jarakB,
  required double radius,
}) {
  final selang = waktuB.difference(waktuA);
  // Interpolasi hanya masuk akal jika dua fix berdekatan (asumsi kecepatan
  // konstan). Jika renggang (misal pegawai sempat berhenti/parkir), jangan
  // menebak: pakai waktu fix kedua yang pasti.
  if (selang.isNegative || selang.inSeconds > 120) return waktuB;
  if ((jarakB - jarakA).abs() < 1) return waktuB;
  final f = ((radius - jarakA) / (jarakB - jarakA)).clamp(0.0, 1.0).toDouble();
  return waktuA.add(Duration(milliseconds: (selang.inMilliseconds * f).round()));
}

Future<void> _logout(BuildContext context) async {
  await FirebaseAuth.instance.signOut();
  if (context.mounted) {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (r) => false,
    );
  }
}

Future<void> _keluarAman(BuildContext context) async {
  if (_bertugasGlobal.value) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Selesaikan tugas dulu sebelum keluar.'),
    ));
    return;
  }
  await _logout(context);
}

Widget _tombolKeluar(BuildContext context) => IconButton(
      icon: const Icon(Icons.logout),
      tooltip: 'Keluar',
      onPressed: () => _keluarAman(context),
    );

Future<Map<String, dynamic>> _profilSaya() async {
  final u = FirebaseAuth.instance.currentUser!;
  final d =
      await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
  return (d.data() as Map<String, dynamic>?) ?? {};
}

// Bersihkan data live, pengajuan, dan hentikan tracking seorang pegawai
Future<void> _bersihkanAkun(String uid) async {
  final db = FirebaseFirestore.instance;
  try {
    await db.collection('kontrol_pegawai').doc(uid).set({
      'stop': true,
      'waktu': FieldValue.serverTimestamp(),
    });
  } catch (_) {}
  try {
    await db.collection('live_lokasi_pegawai').doc(uid).delete();
  } catch (_) {}
  try {
    await _pengajuanCol.doc(uid).delete();
  } catch (_) {}
}

// ---------- Format ----------
String _dua(int n) => n.toString().padLeft(2, '0');

String _formatJam(DateTime t) =>
    '${_dua(t.day)}/${_dua(t.month)}/${t.year} ${_dua(t.hour)}:${_dua(t.minute)}';

String _hms(Duration d) =>
    '${_dua(d.inHours)}:${_dua(d.inMinutes.remainder(60))}:${_dua(d.inSeconds.remainder(60))}';

String _formatDurasi(Duration d) {
  final j = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (j > 0) return '$j jam $m menit $s detik';
  if (m > 0) return '$m menit $s detik';
  return '$s detik';
}

String _formatMenit(Duration d) {
  final j = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (j > 0) return '$j jam $m menit';
  return '$m menit';
}

String _tanggalStr(DateTime d) => '${d.year}-${_dua(d.month)}-${_dua(d.day)}';

String _tglTampil(String s) {
  final p = s.split('-');
  if (p.length != 3) return s;
  return '${p[2]}/${p[1]}/${p[0]}';
}

String _fmtTs(Timestamp? t) {
  if (t == null) return '-';
  final d = t.toDate();
  return '${_dua(d.hour)}:${_dua(d.minute)}';
}

// ---------- Jam kantor ----------
const Map<String, int> _jamDefault = {
  'sk_masuk': 450, // 07:30
  'sk_pulang': 960, // 16:00
  'sk_istMulai': 720, // 12:00
  'sk_istSelesai': 795, // 13:15
  'jm_masuk': 450, // 07:30
  'jm_pulang': 990, // 16:30
  'jm_istMulai': 690, // 11:30
  'jm_istSelesai': 795, // 13:15
};

Map<String, int> _gabungJam(Map<String, dynamic>? d) {
  final r = Map<String, int>.from(_jamDefault);
  if (d != null) {
    for (final k in r.keys.toList()) {
      final v = d[k];
      if (v is num) r[k] = v.toInt();
    }
  }
  return r;
}

String _fmtMenitJam(int m) => '${_dua(m ~/ 60)}:${_dua(m % 60)}';

// 'libur', 'sebelum', 'kerja', 'istirahat', 'sesudah'
String _statusJam(DateTime now, Map<String, int> c) {
  if (now.weekday > 5) return 'libur';
  final p = now.weekday == 5 ? 'jm' : 'sk';
  final m = now.hour * 60 + now.minute;
  if (m < c['${p}_masuk']!) return 'sebelum';
  if (m >= c['${p}_pulang']!) return 'sesudah';
  if (m >= c['${p}_istMulai']! && m < c['${p}_istSelesai']!) {
    return 'istirahat';
  }
  return 'kerja';
}

String _teksJamHariIni(DateTime now, Map<String, int> c) {
  if (now.weekday > 5) return 'Hari libur';
  final p = now.weekday == 5 ? 'jm' : 'sk';
  return 'Kerja ${_fmtMenitJam(c['${p}_masuk']!)}-${_fmtMenitJam(c['${p}_pulang']!)}'
      '  •  Istirahat ${_fmtMenitJam(c['${p}_istMulai']!)}-${_fmtMenitJam(c['${p}_istSelesai']!)}';
}

Query _logQuery(String tanggal, String? tim) {
  Query q = _logCol.where('tanggal', isEqualTo: tanggal);
  if (tim != null) q = q.where('tim', isEqualTo: tim);
  return q;
}

// ---------- Widget bersama ----------
Widget _barisInfo(IconData ikon, String label, String nilai) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ikon, size: 22, color: _biru),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text(nilai,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );

PreferredSizeWidget _appBarBps(String judul, List<Widget> actions,
        {PreferredSizeWidget? bottom}) =>
    AppBar(
      titleSpacing: 12,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image.asset('assets/logo_bps.png', height: 28),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(judul,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      actions: actions,
      bottom: bottom,
    );

Widget _chip(String teks, Color warna) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: warna,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(teks,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
    );

class _DashTabs extends StatelessWidget {
  final String judul;
  final List<Widget> actions;
  final List<String> tabs;
  final List<Widget> views;
  const _DashTabs({
    required this.judul,
    required this.actions,
    required this.tabs,
    required this.views,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: _appBarBps(
          judul,
          actions,
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: _oranye,
            indicatorWeight: 3,
            tabs: tabs.map((t) => Tab(text: t)).toList(),
          ),
        ),
        body: TabBarView(
          physics: const NeverScrollableScrollPhysics(),
          children: views,
        ),
      ),
    );
  }
}

// ==========================================
// HALAMAN PEGAWAI
// ==========================================
class PegawaiHomePage extends StatelessWidget {
  final String peran; // 'pegawai' atau 'kepala_tim'
  const PegawaiHomePage({super.key, this.peran = 'pegawai'});

  @override
  Widget build(BuildContext context) {
    if (peran == 'kepala_tim') return const KepalaTimPage();
    return Scaffold(
      appBar: _appBarBps('Mode Pegawai', [_tombolKeluar(context)]),
      body: const TugasSayaView(peran: 'pegawai'),
    );
  }
}

class TugasSayaView extends StatefulWidget {
  final String peran;
  const TugasSayaView({super.key, required this.peran});

  @override
  State<TugasSayaView> createState() => _TugasSayaViewState();
}

class _TugasSayaViewState extends State<TugasSayaView>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  bool _isTracking = false;
  bool _loading = true;
  bool _sibuk = false;
  bool _dialogAlasan = false;
  bool _foreground = true;
  bool _keluarPaksa = false;
  int _tick = 0;
  StreamSubscription<Position>? _sub;
  StreamSubscription<DocumentSnapshot>? _pengajuanSub;
  StreamSubscription<DocumentSnapshot>? _kontrolSub;
  StreamSubscription<DocumentSnapshot>? _jamSub;
  StreamSubscription<DocumentSnapshot>? _userSub;
  Timer? _ticker;
  Timer? _jadwal;
  Timer? _ulangKirim;
  String _nama = '';
  String _tim = 'Tanpa Tim';
  Timestamp? _mulai;
  Position? _lastPos;
  Position? _fixSebelum; // fix valid sebelum _lastPos
  double? _jarakSebelum;
  Timer? _waspada;
  DateTime _waspadaMulai = DateTime.now();
  int _diam = 0;
  String _waktuTerakhir = '-';
  String _statusMessage = '';
  Map<String, dynamic>? _pengajuan;
  Map<String, int> _jam = Map<String, int>.from(_jamDefault);
  String? _logId;

  // Antrian pengiriman lokasi
  final List<Map<String, dynamic>> _antrian = [];
  bool _mengirim = false;
  DateTime? _berikutnya;
  final Random _acak = Random();
  late final int _slot = _slotDetik(FirebaseAuth.instance.currentUser!.uid);

  String get _uid => FirebaseAuth.instance.currentUser!.uid;
  DocumentReference get _liveRef =>
      FirebaseFirestore.instance.collection('live_lokasi_pegawai').doc(_uid);
  DocumentReference get _pengajuanRef => _pengajuanCol.doc(_uid);
  DocumentReference get _kontrolRef =>
      FirebaseFirestore.instance.collection('kontrol_pegawai').doc(_uid);
  String? get _status => _pengajuan?['status'] as String?;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _lengkapiAlasan();
  }

  // Minta alasan untuk semua catatan keluar yang belum diberi alasan,
  // termasuk yang pegawainya sudah kembali ke kantor.
  Future<void> _lengkapiAlasan() async {
    if (_dialogAlasan) return;
    _dialogAlasan = true;
    try {
      final q = await _logCol
          .where('uid', isEqualTo: _uid)
          .where('perluAlasan', isEqualTo: true)
          .get();
      for (final d in q.docs) {
        if (!mounted) return;
        final m = d.data() as Map<String, dynamic>;
        final jam = _fmtTs(m['jamKeluar'] as Timestamp?);
        final tgl = _tglTampil((m['tanggal'] ?? '').toString());
        final alasan = await _mintaAlasan(
            info:
                'Pada $tgl pukul $jam Anda tercatat berada di luar kantor saat jam kerja. Isi alasannya.');
        if (alasan == null) return;
        await _logCol
            .doc(d.id)
            .update({'keterangan': alasan, 'perluAlasan': false});
      }
    } catch (_) {
    } finally {
      _dialogAlasan = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _tick++;
      if (_tick % 60 == 0) _evaluasi();
      if (_isTracking || _logId != null) setState(() {});
    });
    _init();
  }

  Future<void> _init() async {
    final user = FirebaseAuth.instance.currentUser!;
    try {
      final u = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final ud = u.data() as Map<String, dynamic>?;
      _nama = (ud?['nama'] as String?) ??
          (user.email ?? 'Pegawai').split('@').first;
      _tim = (ud?['tim'] as String?) ?? 'Tanpa Tim';

      final p = await _pengajuanRef.get();
      _pengajuan = p.data() as Map<String, dynamic>?;

      _pengajuanSub = _pengajuanRef.snapshots().listen((s) {
        if (mounted) {
          setState(() => _pengajuan = s.data() as Map<String, dynamic>?);
        }
      }, onError: (_) {});

      _kontrolSub = _kontrolRef.snapshots().listen((s) async {
        final d = s.data() as Map<String, dynamic>?;
        if (d?['stop'] == true && _isTracking) {
          await _kontrolRef.set({'stop': false});
          await _dihentikanAdmin();
        }
      }, onError: (_) {});

      _jamSub = FirebaseFirestore.instance
          .collection('pengaturan')
          .doc('jam_kantor')
          .snapshots()
          .listen((s) {
        if (mounted) {
          setState(() => _jam = _gabungJam(s.data() as Map<String, dynamic>?));
        }
      }, onError: (_) {});

      // Jika akun dinonaktifkan admin saat sedang login
      _userSub = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots()
          .listen((s) {
        final m = s.data() as Map<String, dynamic>?;
        if (m != null && m['is_active'] == false) _akunDinonaktifkan();
      }, onError: (_) {});

      // Cari catatan keluar yang masih terbuka hari ini
      final lg = await _logCol
          .where('uid', isEqualTo: _uid)
          .where('tanggal', isEqualTo: _tanggalStr(DateTime.now()))
          .get();
      for (final d in lg.docs) {
        final m = d.data() as Map<String, dynamic>;
        if (m['jamKembali'] == null) _logId = d.id;
      }

      // Lanjutkan tracking jika sebelumnya aktif
      final live = await _liveRef.get();
      if (live.exists && _status == 'disetujui') {
        final m = live.data() as Map<String, dynamic>?;
        _mulai = m?['mulai'] as Timestamp?;
        _isTracking = true;
        _bertugasGlobal.value = true;
      }

      _lengkapiAlasan(); // tidak ditunggu agar pemantauan tetap mulai
      await _mulaiPantau();
    } catch (e) {
      _statusMessage = 'Gagal memuat data: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _pengajuanSub?.cancel();
    _kontrolSub?.cancel();
    _jamSub?.cancel();
    _userSub?.cancel();
    _ticker?.cancel();
    _jadwal?.cancel();
    _waspada?.cancel();
    _ulangKirim?.cancel();
    _bertugasGlobal.value = false;
    super.dispose();
  }

  Future<void> _akunDinonaktifkan() async {
    if (_keluarPaksa) return;
    _keluarPaksa = true;
    _isTracking = false;
    _bertugasGlobal.value = false;
    _antrian.clear();
    _jadwal?.cancel();
    _hentikanWaspada();
    await _sub?.cancel();
    _sub = null;
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
          builder: (_) => const LoginPage(
              pesan: 'Akun Anda sudah dinonaktifkan. Hubungi admin.')),
      (r) => false,
    );
  }

  Future<bool> _pastikanIzin() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() => _statusMessage = 'GPS tidak aktif. Aktifkan GPS Anda.');
      }
      return false;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _statusMessage = 'Izin lokasi ditolak.');
      return false;
    }
    return true;
  }

  // Pemantauan hemat baterai berbasis gerakan.
  // "Penjaga": akurasi sedang, hanya memberi update jika perangkat
  // berpindah >= 40 m. Diam = tidak ada update. Notifikasi permanen
  // menjaga layanan latar belakang tetap hidup.
  Future<void> _mulaiPantau() async {
    if (_sub != null) return;
    if (!await _pastikanIzin()) return;

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 40,
      intervalDuration: const Duration(seconds: 60),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Monitoring BPS aktif',
        notificationText: 'Lokasi dipantau selama jam kerja',
        notificationChannelName: 'Monitoring lokasi',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPenjaga,
      onError: (e) {
        if (mounted) setState(() => _statusMessage = 'Error GPS: $e');
      },
    );

    _jadwalkanBerikut();
    _ambilPosisiAwal();
  }

  // Update dari "penjaga" (kasar). Hanya dipakai sebagai pemicu:
  // jika perangkat bergerak di dekat batas kantor, nyalakan mode waspada.
  void _onPenjaga(Position p) {
    final d = _jarakKeKantor(p.latitude, p.longitude);
    // Posisi kasar (Wi-Fi/seluler) tetap dipakai sebagai pemicu: zona
    // dilebarkan sebesar ketidakpastiannya (maks 1 km) agar kedatangan
    // tidak terlewat hanya karena akurasi penjaga rendah.
    final margin = p.accuracy.clamp(0.0, 1000.0).toDouble();
    if ((d - _radiusKantor).abs() <= _zonaWaspada + margin) _mulaiWaspada();
  }

  // Mode waspada: GPS akurat tiap 30 detik, maksimal 10 menit,
  // berhenti sendiri jika perangkat diam atau menjauh dari batas.
  void _mulaiWaspada() {
    if (_waspada != null) return;
    _waspadaMulai = DateTime.now();
    _diam = 0;
    _waspadaTik();
    _waspada =
        Timer.periodic(const Duration(seconds: 30), (_) => _waspadaTik());
  }

  void _hentikanWaspada() {
    _waspada?.cancel();
    _waspada = null;
  }

  Future<void> _waspadaTik() async {
    if (!mounted) {
      _hentikanWaspada();
      return;
    }
    try {
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 20));
      final lama = _lastPos;
      final geser = lama == null
          ? 999.0
          : Geolocator.distanceBetween(
              lama.latitude, lama.longitude, p.latitude, p.longitude);
      _diam = geser < 15 ? _diam + 1 : 0;
      await _prosesFix(p);
    } catch (_) {}

    final l = _lastPos;
    final d = l == null ? 0.0 : _jarakKeKantor(l.latitude, l.longitude);
    final menit = DateTime.now().difference(_waspadaMulai).inMinutes;
    if (_diam >= 3 ||
        menit >= 10 ||
        (d - _radiusKantor).abs() > _zonaWaspada + 100) {
      _hentikanWaspada();
    }
  }

  // Semua fix akurat lewat sini, supaya fix sebelumnya tersimpan
  // untuk interpolasi waktu.
  Future<void> _prosesFix(Position p) async {
    if (p.accuracy > 80) return;
    final lama = _lastPos;
    if (lama != null && lama.accuracy <= 80) {
      _fixSebelum = lama;
      _jarakSebelum = _jarakKeKantor(lama.latitude, lama.longitude);
    }
    _lastPos = p;
    await _evaluasi();
    if (mounted) setState(() {});
  }

  Future<void> _ambilPosisiAwal() async {
    try {
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 45));
      await _prosesFix(p);
    } catch (_) {}
  }

  // Jadwal kirim: tiap 10 menit pada slot detik milik pegawai ini
  // (ditambah acak 0-9 detik) sehingga pegawai tidak mengirim bersamaan.
  void _jadwalkanBerikut() {
    _jadwal?.cancel();
    final detik = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var target = (detik ~/ _siklusDetik) * _siklusDetik +
        _slot +
        _acak.nextInt(10);
    if (target <= detik + 5) target += _siklusDetik;
    _berikutnya = DateTime.fromMillisecondsSinceEpoch(target * 1000);
    _jadwal = Timer(Duration(seconds: target - detik), () async {
      if (!mounted) return;
      await _ambilDanKirim();
      if (mounted) _jadwalkanBerikut();
    });
  }

  Future<void> _ambilDanKirim() async {
    try {
      final baru = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 45));
      await _prosesFix(baru);
    } catch (_) {}
    final p = _lastPos;
    if (p == null) return;
    if (_isTracking || _logId != null) _antri(p);
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _paket(Position p) => {
        'uid': _uid,
        'nama': _nama,
        'tim': _tim,
        'peran': widget.peran,
        'latitude': p.latitude,
        'longitude': p.longitude,
        'waktu': p.timestamp.toLocal().toString().substring(0, 19),
        'mulai': _mulai,
        'tujuan': _pengajuan?['tujuan'],
        'keperluan': _pengajuan?['keperluan'],
        'tujuanLat': _pengajuan?['tujuanLat'],
        'tujuanLng': _pengajuan?['tujuanLng'],
        'timestamp': FieldValue.serverTimestamp(),
      };

  void _antri(Position p) {
    _antrian.add(_paket(p));
    while (_antrian.length > 5) {
      _antrian.removeAt(0);
    }
    _prosesAntrian();
  }

  // Antrian FIFO: dikirim satu per satu, jika gagal dicoba lagi
  Future<void> _prosesAntrian() async {
    if (_mengirim) return;
    _mengirim = true;
    try {
      while (_antrian.isNotEmpty && (_isTracking || _logId != null)) {
        final item = _antrian.first;
        await _liveRef.set(item);
        if (_antrian.isNotEmpty) _antrian.removeAt(0);
        if (mounted) {
          setState(() {
            _waktuTerakhir = (item['waktu'] ?? '-').toString();
            _statusMessage = 'Posisi terkirim otomatis (tiap 10 menit).';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Gagal kirim, dicoba lagi: $e');
      }
      _ulangKirim?.cancel();
      _ulangKirim = Timer(const Duration(seconds: 60), _prosesAntrian);
    } finally {
      _mengirim = false;
    }
  }

  // Cek posisi terhadap kantor, catat keluar/kembali.
  // Waktu yang dicatat = waktu FIX GPS (bukan waktu kirim/evaluasi).
  Future<void> _evaluasi() async {
    final p = _lastPos;
    if (p == null || _sibuk) return;
    if (p.accuracy > 80) return; // abaikan jika GPS kurang akurat
    var perluTanya = false;
    _sibuk = true;
    try {
      final d = _jarakKeKantor(p.latitude, p.longitude);
      final prev = _fixSebelum;
      final prevD = _jarakSebelum;

      // Sedang tercatat di luar: dianggap kembali jika jelas di dalam
      if (_logId != null) {
        if (d < _radiusKantor - _histeresis) {
          var tKembali = p.timestamp;
          if (prev != null && prevD != null && prevD > _radiusKantor) {
            tKembali = _perkirakanLintas(
              waktuA: prev.timestamp,
              jarakA: prevD,
              waktuB: p.timestamp,
              jarakB: d,
              radius: _radiusKantor,
            );
          }
          await _logCol
              .doc(_logId)
              .update({'jamKembali': Timestamp.fromDate(tKembali)});
          _logId = null;
          if (!_isTracking) {
            _antrian.clear();
            _liveRef.delete().catchError((_) {});
          }
          if (mounted) setState(() {});
        }
        return;
      }

      // Belum tercatat: keluar hanya jika jelas di luar
      if (d <= _radiusKantor + _histeresis) return;
      if (_statusJam(DateTime.now(), _jam) != 'kerja') return;

      // Perkirakan kapan batas dilewati
      var tKeluar = p.timestamp;
      DateTime? tAwal;
      if (prev != null && prevD != null && prevD <= _radiusKantor) {
        tAwal = prev.timestamp;
        tKeluar = _perkirakanLintas(
          waktuA: prev.timestamp,
          jarakA: prevD,
          waktuB: p.timestamp,
          jarakB: d,
          radius: _radiusKantor,
        );
      }

      String ket;
      bool izin;
      bool perlu = false;
      if (_status == 'disetujui') {
        final t = (_pengajuan?['tujuan'] ?? '').toString();
        final k = (_pengajuan?['keperluan'] ?? '').toString();
        ket = k.isEmpty ? t : '$t - $k';
        izin = true;
      } else {
        // Catat DULU (waktu tidak menunggu pegawai menjawab), alasan menyusul.
        ket = 'Belum diisi (menunggu alasan pegawai)';
        izin = false;
        perlu = true;
      }

      final ref = await _logCol.add({
        'tanggal': _tanggalStr(tKeluar.toLocal()),
        'uid': _uid,
        'nama': _nama,
        'tim': _tim,
        'peran': widget.peran,
        'keterangan': ket,
        'izin': izin,
        'perluAlasan': perlu,
        'jamKeluar': Timestamp.fromDate(tKeluar), // estimasi saat melewati batas
        'jamKeluarAwal': tAwal == null ? null : Timestamp.fromDate(tAwal),
        'jamTerdeteksi': Timestamp.fromDate(p.timestamp), // fix pertama di luar
        'diterima': FieldValue.serverTimestamp(), // waktu server (audit)
        'mock': p.isMocked, // true jika lokasi palsu
        'jamKembali': null,
      });
      _logId = ref.id;
      _antri(p); // langsung tampil di peta atasan
      perluTanya = perlu;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Gagal mencatat: $e');
    } finally {
      _sibuk = false;
    }
    // Aplikasi sedang dilihat: tanyakan alasan sekarang (log sudah tercatat)
    if (perluTanya && _foreground) await _lengkapiAlasan();
  }

  Future<String?> _mintaAlasan({String? info}) async {
    if (!mounted) return null;
    final c = TextEditingController();
    String? err;
    final hasil = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: _oranye),
                SizedBox(width: 8),
                Expanded(child: Text('Anda di luar kantor')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info ??
                    'Sekarang jam kerja. Isi alasan Anda berada di luar kantor.'),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  maxLines: 3,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Alasan / keterangan',
                    errorText: err,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () {
                  if (c.text.trim().isEmpty) {
                    setD(() => err = 'Alasan wajib diisi.');
                    return;
                  }
                  Navigator.pop(ctx, c.text.trim());
                },
                child: const Text('KIRIM'),
              ),
            ],
          ),
        ),
      ),
    );
    return hasil;
  }

  Future<void> _mulaiTugas() async {
    if (_status != 'disetujui') {
      setState(() => _statusMessage = 'Tugas belum disetujui.');
      return;
    }
    if (!await _pastikanIzin()) return;

    final existing = await _liveRef.get();
    final old = existing.data() as Map<String, dynamic>?;
    _mulai = (old?['mulai'] as Timestamp?) ?? Timestamp.now();
    await _kontrolRef.set({'stop': false});

    setState(() {
      _isTracking = true;
      _statusMessage = 'Mengirim posisi otomatis ke server...';
    });
    _bertugasGlobal.value = true;

    await _mulaiPantau();
    try {
      final p = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 45));
      await _prosesFix(p);
      _antri(p); // kirim langsung sekali saat tugas dimulai
    } catch (_) {}
  }

  Future<void> _selesaiTugas() async {
    _isTracking = false;
    _antrian.clear();
    try {
      await _liveRef.delete();
      await _pengajuanRef.delete();
    } catch (_) {}
    _bertugasGlobal.value = false;
    if (mounted) {
      setState(() {
        _mulai = null;
        _statusMessage = 'Tugas selesai. Silakan ajukan tugas berikutnya.';
      });
    }
  }

  Future<void> _dihentikanAdmin() async {
    _isTracking = false;
    _antrian.clear();
    try {
      await _liveRef.delete();
      await _pengajuanRef.delete();
    } catch (_) {}
    _bertugasGlobal.value = false;
    if (mounted) {
      setState(() {
        _mulai = null;
        _statusMessage =
            'Tracking dimatikan oleh Admin. Ajukan ulang jika perlu.';
      });
    }
  }

  Future<void> _batalkanPengajuan() async {
    await _pengajuanRef.delete();
  }

  Future<void> _ajukan() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              FormPengajuanPage(nama: _nama, peran: widget.peran, tim: _tim)),
    );
  }

  Widget _kartuJam() {
    final now = DateTime.now();
    final st = _statusJam(now, _jam);
    const label = {
      'kerja': 'Jam kerja',
      'istirahat': 'Jam istirahat (boleh keluar)',
      'sebelum': 'Belum jam kerja',
      'sesudah': 'Jam kerja selesai',
      'libur': 'Hari libur',
    };
    final p = _lastPos;
    final luar = p == null
        ? null
        : _jarakKeKantor(p.latitude, p.longitude) > _radiusKantor;
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.schedule, color: _biru),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label[st] ?? '',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (luar != null)
                  _chip(luar ? 'Di luar kantor' : 'Di kantor',
                      luar ? _oranye : _hijau),
              ],
            ),
            const SizedBox(height: 6),
            Text(_teksJamHariIni(now, _jam),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (_logId != null) ...[
              const Divider(height: 20),
              const Text(
                'Anda tercatat di luar kantor. Jam kembali akan tercatat otomatis saat Anda tiba di kantor.',
                style: TextStyle(fontSize: 13, color: _oranye),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kartuPengajuan() {
    final st = _status;
    Color warna;
    IconData ikon;
    String judul;
    if (st == 'menunggu') {
      warna = _oranye;
      ikon = Icons.hourglass_top;
      judul = widget.peran == 'kepala_tim'
          ? 'Menunggu persetujuan Kepala BPS'
          : 'Menunggu persetujuan Kepala Tim / Kepala BPS';
    } else if (st == 'disetujui') {
      warna = _hijau;
      ikon = Icons.verified;
      judul = 'Disetujui';
    } else if (st == 'ditolak') {
      warna = Colors.red;
      ikon = Icons.cancel;
      judul = 'Pengajuan ditolak';
    } else {
      warna = Colors.grey;
      ikon = Icons.assignment_outlined;
      judul = 'Belum ada pengajuan tugas';
    }
    final tujuan = _pengajuan?['tujuan'] as String?;
    final keperluan = _pengajuan?['keperluan'] as String?;
    final catatan = _pengajuan?['catatan'] as String?;
    final oleh = _pengajuan?['diputuskanOleh'] as String?;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(ikon, color: warna, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(judul,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: warna)),
              ),
            ]),
            if (tujuan != null) ...[
              const Divider(height: 20),
              _barisInfo(Icons.flag_outlined, 'Tujuan', tujuan),
              if (keperluan != null && keperluan.isNotEmpty)
                _barisInfo(Icons.notes, 'Keperluan', keperluan),
              if (st == 'disetujui' && oleh != null)
                _barisInfo(
                    Icons.verified_user_outlined, 'Disetujui oleh', oleh),
            ],
            if (st == 'ditolak' && catatan != null && catatan.isNotEmpty)
              _barisInfo(Icons.comment_outlined, 'Catatan', catatan),
            const SizedBox(height: 8),
            if (!_isTracking && (st == null || st == 'ditolak'))
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _ajukan,
                  icon: const Icon(Icons.edit_note),
                  label: Text(st == 'ditolak' ? 'AJUKAN ULANG' : 'AJUKAN TUGAS',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            if (st == 'menunggu')
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _batalkanPengajuan,
                  child: const Text('Batalkan pengajuan'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final durasi = (_isTracking && _mulai != null)
        ? DateTime.now().difference(_mulai!.toDate())
        : Duration.zero;
    final inisial = _nama.isEmpty ? '?' : _nama[0].toUpperCase();
    final bisaMulai = _status == 'disetujui';
    final kepalaTim = widget.peran == 'kepala_tim';
    final b = _berikutnya;

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFD6EFFA), Colors.white],
        ),
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: _oranye,
                          child: Text(inisial,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  kepalaTim
                                      ? 'Kepala Tim $_tim'
                                      : 'Tim $_tim',
                                  style: const TextStyle(
                                      fontSize: 13, color: Colors.grey)),
                              Text(_nama,
                                  style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _kartuJam(),
                  const SizedBox(height: 14),
                  _kartuPengajuan(),
                  const SizedBox(height: 14),
                  Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: _isTracking ? _hijau : Colors.grey,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _isTracking ? 'BERTUGAS' : 'TIDAK BERTUGAS',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text('Durasi bertugas',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(
                            _hms(durasi),
                            style: TextStyle(
                              fontSize: 44,
                              fontWeight: FontWeight.w800,
                              color: _isTracking ? _biru : Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton.icon(
                              onPressed: _isTracking
                                  ? _selesaiTugas
                                  : (bisaMulai ? _mulaiTugas : null),
                              icon: Icon(_isTracking
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_arrow_rounded),
                              label: Text(
                                _isTracking ? 'SELESAI TUGAS' : 'MULAI TUGAS',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    _isTracking ? Colors.red : _hijau,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: Colors.grey.shade300,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                          if (!_isTracking && !bisaMulai)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'Tombol aktif setelah pengajuan disetujui.',
                                style:
                                    TextStyle(fontSize: 12, color: Colors.grey),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_isTracking) ...[
                    const SizedBox(height: 14),
                    Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Detail Pelacakan',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: _biru)),
                            const Divider(height: 20),
                            _barisInfo(
                                Icons.play_circle_outline,
                                'Mulai tugas',
                                _mulai == null
                                    ? '-'
                                    : _formatJam(_mulai!.toDate())),
                            _barisInfo(Icons.update, 'Update terakhir',
                                _waktuTerakhir),
                            _barisInfo(
                                Icons.schedule_send,
                                'Pengiriman berikutnya',
                                b == null
                                    ? '-'
                                    : '${_dua(b.hour)}:${_dua(b.minute)}:${_dua(b.second)}'),
                            _barisInfo(
                                Icons.place_outlined,
                                'Koordinat',
                                _lastPos == null
                                    ? '-'
                                    : '${_lastPos!.latitude.toStringAsFixed(6)}, ${_lastPos!.longitude.toStringAsFixed(6)}'),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(_statusMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black54)),
                  ],
                ],
              ),
            ),
    );
  }
}

// ---------- FORM PENGAJUAN ----------
class FormPengajuanPage extends StatefulWidget {
  final String nama;
  final String peran;
  final String tim;
  const FormPengajuanPage(
      {super.key,
      required this.nama,
      this.peran = 'pegawai',
      this.tim = 'Tanpa Tim'});

  @override
  State<FormPengajuanPage> createState() => _FormPengajuanPageState();
}

class _FormPengajuanPageState extends State<FormPengajuanPage> {
  final _tujuanC = TextEditingController();
  final _keperluanC = TextEditingController();
  LatLng? _titik;
  bool _kirim = false;
  String? _error;

  @override
  void dispose() {
    _tujuanC.dispose();
    _keperluanC.dispose();
    super.dispose();
  }

  Future<void> _pilihTitik() async {
    final hasil = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => PilihTitikPage(awal: _titik)),
    );
    if (hasil != null) setState(() => _titik = hasil);
  }

  Future<void> _ajukan() async {
    if (_tujuanC.text.trim().isEmpty) {
      setState(() => _error = 'Nama tujuan wajib diisi.');
      return;
    }
    if (_titik == null) {
      setState(() => _error = 'Pilih titik tujuan di peta.');
      return;
    }
    setState(() {
      _kirim = true;
      _error = null;
    });
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await _pengajuanCol.doc(uid).set({
        'uid': uid,
        'nama': widget.nama,
        'peran': widget.peran,
        'tim': widget.tim,
        'tujuan': _tujuanC.text.trim(),
        'keperluan': _keperluanC.text.trim(),
        'tujuanLat': _titik!.latitude,
        'tujuanLng': _titik!.longitude,
        'status': 'menunggu',
        'catatan': '',
        'dibuat': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = 'Gagal mengajukan: $e');
    } finally {
      if (mounted) setState(() => _kirim = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBarBps('Ajukan Tugas', []),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _tujuanC,
              decoration: InputDecoration(
                labelText: 'Tujuan (nama tempat / instansi)',
                prefixIcon: const Icon(Icons.flag_outlined),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _keperluanC,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Keperluan',
                prefixIcon: const Icon(Icons.notes),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _pilihTitik,
                icon: const Icon(Icons.map_outlined),
                label: Text(_titik == null
                    ? 'Pilih titik tujuan di peta'
                    : 'Titik dipilih: ${_titik!.latitude.toStringAsFixed(5)}, ${_titik!.longitude.toStringAsFixed(5)}'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _kirim ? null : _ajukan,
                child: _kirim
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('KIRIM PENGAJUAN',
                        style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- PILIH TITIK DI PETA ----------
class PilihTitikPage extends StatefulWidget {
  final LatLng? awal;
  const PilihTitikPage({super.key, this.awal});

  @override
  State<PilihTitikPage> createState() => _PilihTitikPageState();
}

class _PilihTitikPageState extends State<PilihTitikPage> {
  LatLng? _dipilih;

  @override
  void initState() {
    super.initState();
    _dipilih = widget.awal;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBarBps('Pilih Titik Tujuan', []),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: widget.awal ?? _kantor,
              initialZoom: 15,
              onTap: (tapPosition, point) => setState(() => _dipilih = point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'id.go.bps.sistatik',
              ),
              if (_dipilih != null)
                MarkerLayer(markers: [
                  Marker(
                    point: _dipilih!,
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.location_pin,
                        color: Colors.red, size: 44),
                  ),
                ]),
            ],
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _dipilih == null
                    ? null
                    : () => Navigator.pop(context, _dipilih),
                child: Text(
                    _dipilih == null
                        ? 'Ketuk peta untuk memilih titik'
                        : 'GUNAKAN TITIK INI',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// PETA LIVE (dipakai Admin, Kepala Tim, Kepala BPS)
// ==========================================
class _PetaLive extends StatefulWidget {
  final String? tim; // null = semua tim
  final String? hanyaPeran; // null = semua peran
  final bool bisaMatikan;
  const _PetaLive({this.tim, this.hanyaPeran, this.bisaMatikan = false});

  @override
  State<_PetaLive> createState() => _PetaLiveState();
}

class _PetaLiveState extends State<_PetaLive> {
  final MapController _map = MapController();
  late final Stream<QuerySnapshot> _stream;

  @override
  void initState() {
    super.initState();
    Query q = FirebaseFirestore.instance.collection('live_lokasi_pegawai');
    if (widget.tim != null) q = q.where('tim', isEqualTo: widget.tim);
    _stream = q.snapshots();
  }

  void _tampilInfo(Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          _InfoPegawaiSheet(data: data, bisaMatikan: widget.bisaMatikan),
    );
  }

  void _fokus(Map<String, dynamic> data) {
    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    _map.move(LatLng(lat, lng), 17);
    _tampilInfo(data);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _stream,
      builder: (context, snapshot) {
        final list = <Map<String, dynamic>>[];
        for (final d in snapshot.data?.docs ?? []) {
          final data = d.data() as Map<String, dynamic>;
          if (data['latitude'] == null || data['longitude'] == null) continue;
          if (widget.hanyaPeran != null &&
              (data['peran'] ?? 'pegawai') != widget.hanyaPeran) {
            continue;
          }
          data['uid'] ??= d.id;
          list.add(data);
        }
        list.sort((a, b) => ((a['nama'] ?? '') as String)
            .compareTo((b['nama'] ?? '') as String));

        final markers = <Marker>[];
        for (final data in list) {
          final nama = (data['nama'] as String?) ?? 'Pegawai';
          final dalam = _diKantor(data);
          final inisial =
              nama.trim().isEmpty ? '?' : nama.trim()[0].toUpperCase();
          final p = LatLng((data['latitude'] as num).toDouble(),
              (data['longitude'] as num).toDouble());
          markers.add(
            Marker(
              point: p,
              width: 100,
              height: 80,
              child: GestureDetector(
                onTap: () => _tampilInfo(data),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: dalam ? _hijau : _oranye,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black38)
                        ],
                      ),
                      child: Text(inisial,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(nama,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: list.isEmpty
                    ? _kantor
                    : LatLng((list.first['latitude'] as num).toDouble(),
                        (list.first['longitude'] as num).toDouble()),
                initialZoom: 17.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.monitoring_pegawai',
                ),
                CircleLayer(circles: [
                  CircleMarker(
                    point: _kantor,
                    radius: _radiusKantor,
                    useRadiusInMeter: true,
                    color: _biru.withAlpha(40),
                    borderColor: _biru,
                    borderStrokeWidth: 2,
                  ),
                ]),
                MarkerLayer(markers: [
                  const Marker(
                    point: _kantor,
                    width: 40,
                    height: 40,
                    child: Icon(Icons.business, color: _biru, size: 32),
                  ),
                  ...markers,
                ]),
              ],
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [
                    BoxShadow(blurRadius: 6, color: Colors.black26)
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle,
                        size: 12, color: list.isEmpty ? Colors.grey : _hijau),
                    const SizedBox(width: 8),
                    Text('${list.length} pegawai aktif',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                  ],
                ),
              ),
            ),
            if (list.isEmpty)
              const Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('Belum ada pegawai yang aktif tracking.',
                        textAlign: TextAlign.center),
                  ),
                ),
              )
            else
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: SizedBox(
                  height: 84,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    scrollDirection: Axis.horizontal,
                    itemCount: list.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final data = list[i];
                      final nama = (data['nama'] as String?) ?? 'Pegawai';
                      final dalam = _diKantor(data);
                      return GestureDetector(
                        onTap: () => _fokus(data),
                        child: Container(
                          width: 200,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: const [
                              BoxShadow(blurRadius: 6, color: Colors.black26)
                            ],
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: dalam ? _hijau : _oranye,
                                child: Text(
                                    nama.isEmpty ? '?' : nama[0].toUpperCase(),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(nama,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15)),
                                    Text(
                                      dalam ? 'Di kantor' : 'Dinas di luar',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: dalam ? _hijau : _oranye),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InfoPegawaiSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final bool bisaMatikan;
  const _InfoPegawaiSheet({required this.data, this.bisaMatikan = false});

  @override
  State<_InfoPegawaiSheet> createState() => _InfoPegawaiSheetState();
}

class _InfoPegawaiSheetState extends State<_InfoPegawaiSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _matikanTracking() async {
    final uid = widget.data['uid'] as String?;
    final nama = (widget.data['nama'] as String?) ?? 'Pegawai';
    if (uid == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Matikan tracking?'),
        content: Text('Live tracking $nama akan dihentikan.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Matikan', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;

    final db = FirebaseFirestore.instance;
    await db.collection('kontrol_pegawai').doc(uid).set({
      'stop': true,
      'waktu': FieldValue.serverTimestamp(),
    });
    await db.collection('live_lokasi_pegawai').doc(uid).delete();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final nama = (widget.data['nama'] as String?) ?? 'Pegawai';
    final tim = (widget.data['tim'] as String?) ?? '-';
    final mulai = (widget.data['mulai'] as Timestamp?)?.toDate();
    final update = widget.data['waktu'] as String? ?? '-';
    final lat = (widget.data['latitude'] as num).toDouble();
    final lng = (widget.data['longitude'] as num).toDouble();
    final jarak = _jarakKeKantor(lat, lng);
    final dalam = jarak <= _radiusKantor;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: dalam ? _hijau : _oranye,
                foregroundColor: Colors.white,
                child: Text(nama.isEmpty ? '?' : nama[0].toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(nama,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              _chip(dalam ? 'Di kantor' : 'Dinas di luar',
                  dalam ? _hijau : _oranye),
            ],
          ),
          const Divider(height: 28),
          _barisInfo(Icons.groups_outlined, 'Tim', tim),
          _barisInfo(Icons.play_circle_outline, 'Mulai tugas',
              mulai == null ? '-' : _formatJam(mulai)),
          _barisInfo(
              Icons.timer_outlined,
              'Lama bertugas',
              mulai == null
                  ? '-'
                  : _formatDurasi(DateTime.now().difference(mulai))),
          _barisInfo(
              Icons.social_distance,
              'Jarak ke kantor',
              jarak >= 1000
                  ? '${(jarak / 1000).toStringAsFixed(2)} km'
                  : '${jarak.toStringAsFixed(0)} meter'),
          _barisInfo(Icons.update, 'Update lokasi terakhir', update),
          _barisInfo(Icons.place_outlined, 'Koordinat',
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'),
          if (widget.data['tujuan'] != null) ...[
            _barisInfo(Icons.flag_outlined, 'Tujuan',
                widget.data['tujuan'].toString()),
            if ((widget.data['keperluan'] ?? '').toString().isNotEmpty)
              _barisInfo(Icons.notes, 'Keperluan',
                  widget.data['keperluan'].toString()),
            if (widget.data['tujuanLat'] != null)
              Builder(builder: (_) {
                final jt = const Distance().as(
                    LengthUnit.Meter,
                    LatLng((widget.data['tujuanLat'] as num).toDouble(),
                        (widget.data['tujuanLng'] as num).toDouble()),
                    LatLng(lat, lng));
                final sampai = jt <= 200;
                return _barisInfo(
                  sampai ? Icons.check_circle : Icons.directions_walk,
                  'Posisi terhadap tujuan',
                  sampai
                      ? 'Sudah di lokasi tujuan (${jt.toStringAsFixed(0)} m)'
                      : 'Belum sampai, ${jt >= 1000 ? '${(jt / 1000).toStringAsFixed(2)} km' : '${jt.toStringAsFixed(0)} m'} dari tujuan',
                );
              }),
          ],
          if (widget.bisaMatikan) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _matikanTracking,
                icon: const Icon(Icons.gps_off),
                label: const Text('MATIKAN TRACKING',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ==========================================
// DAFTAR SEDANG KELUAR (belum kembali)
// ==========================================
class _SedangKeluarView extends StatefulWidget {
  final String? tim;
  final String? hanyaPeran;
  const _SedangKeluarView({this.tim, this.hanyaPeran});

  @override
  State<_SedangKeluarView> createState() => _SedangKeluarViewState();
}

class _SedangKeluarViewState extends State<_SedangKeluarView> {
  Timer? _t;
  late final Stream<QuerySnapshot> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _logQuery(_tanggalStr(DateTime.now()), widget.tim).snapshots();
    _t = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final rows = <Map<String, dynamic>>[];
        for (final d in snapshot.data?.docs ?? []) {
          final m = d.data() as Map<String, dynamic>;
          if (m['jamKembali'] != null) continue;
          if (widget.hanyaPeran != null &&
              (m['peran'] ?? 'pegawai') != widget.hanyaPeran) {
            continue;
          }
          rows.add(m);
        }
        rows.sort((a, b) {
          final x = (a['jamKeluar'] as Timestamp?)?.toDate() ?? DateTime.now();
          final y = (b['jamKeluar'] as Timestamp?)?.toDate() ?? DateTime.now();
          return x.compareTo(y);
        });

        return Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: rows.isEmpty ? _hijau : _oranye,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(rows.isEmpty ? Icons.business : Icons.directions_walk,
                      color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rows.isEmpty
                          ? 'Semua pegawai berada di kantor'
                          : '${rows.length} pegawai sedang di luar kantor',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final m = rows[i];
                  final nama = (m['nama'] as String?) ?? 'Pegawai';
                  final keluar = m['jamKeluar'] as Timestamp?;
                  final izin = m['izin'] != false;
                  return Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: _oranye,
                                child: Text(
                                    nama.isEmpty ? '?' : nama[0].toUpperCase(),
                                    style:
                                        const TextStyle(color: Colors.white)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(nama,
                                        style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold)),
                                    Text('Tim ${m['tim'] ?? '-'}',
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              if ((m['peran'] ?? 'pegawai') == 'kepala_tim')
                                _chip('Kepala Tim', _biru),
                              const SizedBox(width: 6),
                              _chip(izin ? 'Izin' : 'Tanpa izin',
                                  izin ? _hijau : Colors.red),
                            ],
                          ),
                          const Divider(height: 18),
                          _barisInfo(Icons.notes, 'Keterangan',
                              (m['keterangan'] ?? '-').toString()),
                          _barisInfo(
                              Icons.logout,
                              'Keluar',
                              keluar == null
                                  ? '-'
                                  : '${_fmtTs(keluar)}  •  ${_formatMenit(DateTime.now().difference(keluar.toDate()))} yang lalu'),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ==========================================
// REKAP (TABEL)
// ==========================================
class _RekapView extends StatefulWidget {
  final String? tim;
  final String? hanyaPeran;
  final bool kelompokTim;
  const _RekapView({this.tim, this.hanyaPeran, this.kelompokTim = false});

  @override
  State<_RekapView> createState() => _RekapViewState();
}

class _RekapViewState extends State<_RekapView> {
  DateTime _tgl = DateTime.now();
  late Stream<QuerySnapshot> _stream;

  @override
  void initState() {
    super.initState();
    _stream = _logQuery(_tanggalStr(_tgl), widget.tim).snapshots();
  }

  void _setTgl(DateTime d) {
    setState(() {
      _tgl = d;
      _stream = _logQuery(_tanggalStr(_tgl), widget.tim).snapshots();
    });
  }

  Future<void> _pilihTanggal() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _tgl,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (d != null) _setTgl(d);
  }

  Widget _tabel(List<Map<String, dynamic>> rows) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowColor: WidgetStatePropertyAll(_biru.withAlpha(30)),
        columns: const [
          DataColumn(label: Text('Tanggal')),
          DataColumn(label: Text('Nama')),
          DataColumn(label: Text('Tim')),
          DataColumn(label: Text('Keterangan di luar')),
          DataColumn(label: Text('Jam keluar')),
          DataColumn(label: Text('Jam kembali')),
        ],
        rows: rows.map((m) {
          final kt = (m['peran'] ?? 'pegawai') == 'kepala_tim';
          final izin = m['izin'] != false;
          final ket = (m['keterangan'] ?? '-').toString() +
              (izin ? '' : ' (tanpa izin)');
          return DataRow(cells: [
            DataCell(Text(_tglTampil((m['tanggal'] ?? '-').toString()))),
            DataCell(Text('${m['nama'] ?? '-'}${kt ? ' (Kepala Tim)' : ''}')),
            DataCell(Text((m['tim'] ?? '-').toString())),
            DataCell(ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child:
                  Text(ket, style: TextStyle(color: izin ? null : Colors.red)),
            )),
            DataCell(Text(_fmtTs(m['jamKeluar'] as Timestamp?))),
            DataCell(Text(m['jamKembali'] == null
                ? 'Belum kembali'
                : _fmtTs(m['jamKembali'] as Timestamp?))),
          ]);
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hariIni = _tanggalStr(_tgl) == _tanggalStr(DateTime.now());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () =>
                    _setTgl(_tgl.subtract(const Duration(days: 1))),
              ),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pilihTanggal,
                  icon: const Icon(Icons.calendar_today, size: 18),
                  label: Text(_tglTampil(_tanggalStr(_tgl))),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: hariIni
                    ? null
                    : () => _setTgl(_tgl.add(const Duration(days: 1))),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: _stream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Error: ${snapshot.error}'));
              }
              final rows = <Map<String, dynamic>>[];
              for (final d in snapshot.data?.docs ?? []) {
                final m = d.data() as Map<String, dynamic>;
                if (widget.hanyaPeran != null &&
                    (m['peran'] ?? 'pegawai') != widget.hanyaPeran) {
                  continue;
                }
                rows.add(m);
              }
              rows.sort((a, b) {
                final x =
                    (a['jamKeluar'] as Timestamp?)?.toDate() ?? DateTime.now();
                final y =
                    (b['jamKeluar'] as Timestamp?)?.toDate() ?? DateTime.now();
                return x.compareTo(y);
              });

              if (rows.isEmpty) {
                return const Center(
                  child: Text('Tidak ada data keluar kantor pada tanggal ini.',
                      style: TextStyle(color: Colors.grey)),
                );
              }

              if (!widget.kelompokTim) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: _tabel(rows),
                );
              }

              final grup = <String, List<Map<String, dynamic>>>{};
              for (final m in rows) {
                grup
                    .putIfAbsent((m['tim'] ?? 'Tanpa Tim').toString(),
                        () => <Map<String, dynamic>>[])
                    .add(m);
              }
              final namaTim = grup.keys.toList()..sort();
              return ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  for (final t in namaTim) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: _biru,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('Tim $t  (${grup[t]!.length})',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                    _tabel(grup[t]!),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ==========================================
// PERSETUJUAN
// ==========================================
class _PersetujuanView extends StatefulWidget {
  final String? tim; // null = semua tim
  final String? peranFilter; // null = semua peran
  const _PersetujuanView({this.tim, this.peranFilter});

  @override
  State<_PersetujuanView> createState() => _PersetujuanViewState();
}

class _PersetujuanViewState extends State<_PersetujuanView> {
  String _st = 'menunggu';

  @override
  Widget build(BuildContext context) {
    const label = {
      'menunggu': 'Menunggu',
      'disetujui': 'Disetujui',
      'ditolak': 'Ditolak',
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Wrap(
            spacing: 8,
            children: [
              for (final s in label.keys)
                ChoiceChip(
                  label: Text(label[s]!),
                  selected: _st == s,
                  onSelected: (_) => setState(() => _st = s),
                ),
            ],
          ),
        ),
        Expanded(
          child: _DaftarPengajuan(
            key: ValueKey(_st),
            status: _st,
            tim: widget.tim,
            peranFilter: widget.peranFilter,
          ),
        ),
      ],
    );
  }
}

class _DaftarPengajuan extends StatelessWidget {
  final String status;
  final String? tim;
  final String? peranFilter;
  const _DaftarPengajuan(
      {super.key, required this.status, this.tim, this.peranFilter});

  Future<void> _putuskan(
      BuildContext context, String uid, String nama, bool setuju) async {
    String catatan = '';
    if (!setuju) {
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Tolak pengajuan $nama?'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'Alasan (opsional)'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Batal')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('Tolak', style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (ok != true) return;
      catatan = c.text.trim();
    }
    final me = FirebaseAuth.instance.currentUser!;
    final u =
        await FirebaseFirestore.instance.collection('users').doc(me.uid).get();
    final namaPemutus =
        ((u.data() as Map<String, dynamic>?)?['nama'] as String?) ?? 'Pimpinan';
    await _pengajuanCol.doc(uid).update({
      'status': setuju ? 'disetujui' : 'ditolak',
      'catatan': catatan,
      'diputuskan': FieldValue.serverTimestamp(),
      'diputuskanOleh': namaPemutus,
    });
  }

  @override
  Widget build(BuildContext context) {
    Query q = _pengajuanCol.where('status', isEqualTo: status);
    if (tim != null) q = q.where('tim', isEqualTo: tim);

    return StreamBuilder<QuerySnapshot>(
      stream: q.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final docs = (snapshot.data?.docs ?? []).where((x) {
          if (peranFilter == null) return true;
          final d = x.data() as Map<String, dynamic>;
          return (d['peran'] ?? 'pegawai') == peranFilter;
        }).toList();
        if (docs.isEmpty) {
          return const Center(
            child: Text('Tidak ada pengajuan.',
                style: TextStyle(color: Colors.grey)),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final d = docs[i].data() as Map<String, dynamic>;
            final uid = docs[i].id;
            final nama = (d['nama'] as String?) ?? 'Pegawai';
            final dibuat = (d['dibuat'] as Timestamp?)?.toDate();
            final oleh = d['diputuskanOleh'] as String?;
            final catatan = (d['catatan'] ?? '').toString();
            return Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      CircleAvatar(
                        backgroundColor: _oranye,
                        child: Text(nama.isEmpty ? '?' : nama[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nama,
                                style: const TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.bold)),
                            Text('Tim ${d['tim'] ?? '-'}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                      if ((d['peran'] ?? 'pegawai') == 'kepala_tim')
                        _chip('Kepala Tim', _biru),
                    ]),
                    const Divider(height: 20),
                    _barisInfo(Icons.flag_outlined, 'Tujuan',
                        (d['tujuan'] ?? '-').toString()),
                    _barisInfo(Icons.notes, 'Keperluan',
                        (d['keperluan'] ?? '-').toString()),
                    _barisInfo(Icons.schedule, 'Diajukan',
                        dibuat == null ? '-' : _formatJam(dibuat)),
                    if (status != 'menunggu' && oleh != null)
                      _barisInfo(
                          Icons.verified_user_outlined,
                          status == 'disetujui'
                              ? 'Disetujui oleh'
                              : 'Ditolak oleh',
                          oleh),
                    if (status == 'ditolak' && catatan.isNotEmpty)
                      _barisInfo(Icons.comment_outlined, 'Alasan', catatan),
                    if (status == 'menunggu')
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  _putuskan(context, uid, nama, false),
                              child: const Text('TOLAK',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () =>
                                  _putuskan(context, uid, nama, true),
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: _hijau),
                              child: const Text('SETUJUI',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ==========================================
// DASHBOARD ADMIN
// ==========================================
class AdminDashboardLivePage extends StatelessWidget {
  const AdminDashboardLivePage({super.key});

  @override
  Widget build(BuildContext context) {
    return _DashTabs(
      judul: 'Dasbor Admin',
      actions: [
        IconButton(
          icon: const Icon(Icons.schedule),
          tooltip: 'Jam Kantor',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const JamKantorPage()),
          ),
        ),
        _tombolKeluar(context),
      ],
      tabs: const [
        'Peta',
        'Sedang Keluar',
        'Rekap',
        'Daftar Pegawai',
        'Database'
      ],
      views: const [
        _PetaLive(bisaMatikan: true),
        _SedangKeluarView(),
        _RekapAdminView(),
        _DaftarAkunView(),
        _DatabaseView(),
      ],
    );
  }
}

// ---------- PENGATURAN JAM KANTOR ----------
class JamKantorPage extends StatefulWidget {
  const JamKantorPage({super.key});

  @override
  State<JamKantorPage> createState() => _JamKantorPageState();
}

class _JamKantorPageState extends State<JamKantorPage> {
  Map<String, int> _c = Map<String, int>.from(_jamDefault);
  bool _loading = true;
  bool _simpan = false;

  @override
  void initState() {
    super.initState();
    _muat();
  }

  Future<void> _muat() async {
    try {
      final d = await FirebaseFirestore.instance
          .collection('pengaturan')
          .doc('jam_kantor')
          .get();
      _c = _gabungJam(d.data() as Map<String, dynamic>?);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pilih(String key) async {
    final m = _c[key]!;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
    );
    if (t != null) setState(() => _c[key] = t.hour * 60 + t.minute);
  }

  bool _valid(String p) =>
      _c['${p}_masuk']! < _c['${p}_istMulai']! &&
      _c['${p}_istMulai']! < _c['${p}_istSelesai']! &&
      _c['${p}_istSelesai']! < _c['${p}_pulang']!;

  Future<void> _simpanKe() async {
    if (!_valid('sk') || !_valid('jm')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Urutan jam harus: masuk < mulai istirahat < selesai istirahat < pulang.'),
      ));
      return;
    }
    setState(() => _simpan = true);
    try {
      await FirebaseFirestore.instance
          .collection('pengaturan')
          .doc('jam_kantor')
          .set(_c);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Jam kantor tersimpan.')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gagal menyimpan: $e')));
      }
    } finally {
      if (mounted) setState(() => _simpan = false);
    }
  }

  Widget _kelompok(String judul, String p) {
    Widget baris(IconData ikon, String label, String key) => ListTile(
          dense: true,
          leading: Icon(ikon, color: _biru),
          title: Text(label),
          trailing: Text(_fmtMenitJam(_c[key]!),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          onTap: () => _pilih(key),
        );
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(judul,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold, color: _biru)),
            ),
            baris(Icons.login, 'Jam masuk', '${p}_masuk'),
            baris(Icons.free_breakfast, 'Mulai istirahat', '${p}_istMulai'),
            baris(Icons.restaurant, 'Selesai istirahat', '${p}_istSelesai'),
            baris(Icons.logout, 'Jam pulang', '${p}_pulang'),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBarBps('Jam Kantor', []),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                    'Pegawai boleh keluar saat jam istirahat. Di luar jam istirahat, keluar kantor wajib disertai keterangan.',
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 12),
                _kelompok('Senin - Kamis', 'sk'),
                const SizedBox(height: 12),
                _kelompok('Jumat', 'jm'),
                const SizedBox(height: 16),
                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _simpan ? null : _simpanKe,
                    child: _simpan
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('SIMPAN',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
    );
  }
}

// ==========================================
// DAFTAR PEGAWAI (CRUD + AKTIF / NONAKTIF)
// ==========================================
class _DaftarAkunView extends StatefulWidget {
  const _DaftarAkunView();

  @override
  State<_DaftarAkunView> createState() => _DaftarAkunViewState();
}

class _DaftarAkunViewState extends State<_DaftarAkunView> {
  final _cariC = TextEditingController();
  String _filter = 'semua';
  late final Stream<QuerySnapshot> _users =
      FirebaseFirestore.instance.collection('users').snapshots();

  String get _meUid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void dispose() {
    _cariC.dispose();
    super.dispose();
  }

  void _pesan(String teks) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(teks)));
  }

  Future<void> _setAktif(String uid, String nama, bool aktif) async {
    if (!aktif) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Nonaktifkan $nama?'),
          content: const Text(
              'Akun tidak bisa login dan tidak bisa ditracking. Tracking yang sedang berjalan dihentikan.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Batal')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Nonaktifkan',
                    style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'is_active': aktif});
      if (!aktif) await _bersihkanAkun(uid);
      if (mounted) {
        _pesan(aktif ? '$nama diaktifkan.' : '$nama dinonaktifkan.');
      }
    } catch (e) {
      if (mounted) _pesan('Gagal mengubah status: $e');
    }
  }

  Future<void> _hapus(String uid, String nama) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus $nama?'),
        content: const Text(
            'Data akun dihapus dan tidak bisa masuk lagi. Email login tetap tercatat di Firebase Authentication. Disarankan memakai "Nonaktifkan" kecuali akun dibuat salah.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Hapus', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _bersihkanAkun(uid);
      await FirebaseFirestore.instance.collection('users').doc(uid).delete();
      if (mounted) _pesan('$nama dihapus.');
    } catch (e) {
      if (mounted) _pesan('Gagal menghapus: $e');
    }
  }

  void _buka({String? uid, Map<String, dynamic>? data}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _FormAkunPage(uid: uid, data: data)),
    );
  }

  Widget _kartu(Map<String, dynamic> m) {
    final uid = m['_id'] as String;
    final nama = (m['nama'] ?? '-').toString();
    final aktif = m['is_active'] != false;
    final diriSendiri = uid == _meUid;
    final role = (m['role'] ?? '-').toString();
    final tim = m['tim'];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: aktif ? _oranye : Colors.grey,
                  child: Text(nama.isEmpty ? '?' : nama[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(nama,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: aktif ? null : Colors.grey)),
                          ),
                          const SizedBox(width: 6),
                          _chip(aktif ? 'Aktif' : 'Nonaktif',
                              aktif ? _hijau : Colors.grey),
                        ],
                      ),
                      Text(
                          '${_labelPeran[role] ?? role}'
                          '${tim != null ? '  •  Tim $tim' : ''}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                      Text((m['email'] ?? '-').toString(),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
                Switch(
                  value: aktif,
                  activeTrackColor: _hijau,
                  onChanged:
                      diriSendiri ? null : (v) => _setAktif(uid, nama, v),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _buka(uid: uid, data: m),
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Edit'),
                ),
                TextButton.icon(
                  onPressed: diriSendiri ? null : () => _hapus(uid, nama),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Hapus'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _buka(),
        backgroundColor: _oranye,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('Tambah Akun'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _users,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final semua = <Map<String, dynamic>>[];
          for (final d in snapshot.data?.docs ?? []) {
            final m = Map<String, dynamic>.from(d.data() as Map<String, dynamic>);
            m['_id'] = d.id;
            semua.add(m);
          }
          final jmlAktif = semua.where((m) => m['is_active'] != false).length;
          final kata = _cariC.text.trim().toLowerCase();

          final tampil = semua.where((m) {
            final aktif = m['is_active'] != false;
            if (_filter == 'aktif' && !aktif) return false;
            if (_filter == 'nonaktif' && aktif) return false;
            if (kata.isEmpty) return true;
            final teks =
                '${m['nama'] ?? ''} ${m['email'] ?? ''} ${m['tim'] ?? ''}'
                    .toLowerCase();
            return teks.contains(kata);
          }).toList();

          const urutan = {'admin': 0, 'pimpinan': 1, 'kepala_tim': 2, 'pegawai': 3};
          tampil.sort((a, b) {
            final x = urutan[a['role']] ?? 9;
            final y = urutan[b['role']] ?? 9;
            if (x != y) return x.compareTo(y);
            return (a['nama'] ?? '')
                .toString()
                .compareTo((b['nama'] ?? '').toString());
          });

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _biru,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.groups, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                          '${semua.length} akun  •  $jmlAktif aktif  •  ${semua.length - jmlAktif} nonaktif',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cariC,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Cari nama, email, atau tim',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in const {
                    'semua': 'Semua',
                    'aktif': 'Aktif',
                    'nonaktif': 'Nonaktif',
                  }.entries)
                    ChoiceChip(
                      label: Text(f.value),
                      selected: _filter == f.key,
                      onSelected: (_) => setState(() => _filter = f.key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (tampil.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('Tidak ada akun.',
                        style: TextStyle(color: Colors.grey)),
                  ),
                ),
              for (final m in tampil) _kartu(m),
            ],
          );
        },
      ),
    );
  }
}

class _FormAkunPage extends StatefulWidget {
  final String? uid; // null = akun baru
  final Map<String, dynamic>? data;
  const _FormAkunPage({this.uid, this.data});

  @override
  State<_FormAkunPage> createState() => _FormAkunPageState();
}

class _FormAkunPageState extends State<_FormAkunPage> {
  late final bool _edit = widget.uid != null;
  late final TextEditingController _namaC =
      TextEditingController(text: (widget.data?['nama'] ?? '').toString());
  late final TextEditingController _emailC =
      TextEditingController(text: (widget.data?['email'] ?? '').toString());
  final _passC = TextEditingController();
  late String _role = (widget.data?['role'] ?? 'pegawai').toString();
  String? _tim;
  late bool _aktif = widget.data?['is_active'] != false;
  bool _busy = false;
  String? _pesan;

  bool get _diriSendiri =>
      _edit && widget.uid == FirebaseAuth.instance.currentUser!.uid;
  bool get _akunAdmin => _role == 'admin';
  bool get _perluTim => _role == 'pegawai' || _role == 'kepala_tim';

  @override
  void initState() {
    super.initState();
    _tim = widget.data?['tim'] as String?;
  }

  @override
  void dispose() {
    _namaC.dispose();
    _emailC.dispose();
    _passC.dispose();
    super.dispose();
  }

  InputDecoration _dek(String label, IconData ikon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(ikon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  List<DropdownMenuItem<String>> _itemTim() {
    final items = <String>[..._daftarTim];
    if (_tim != null && _tim!.isNotEmpty && !items.contains(_tim)) {
      items.add(_tim!);
    }
    return items
        .map((t) => DropdownMenuItem(
              value: t,
              child: Text(_daftarTim.contains(t)
                  ? 'Tim $t'
                  : '$t (tim lama, pilih tim baru)'),
            ))
        .toList();
  }

  Future<void> _kirimResetPassword() async {
    final email = _emailC.text.trim();
    if (email.isEmpty) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        setState(() => _pesan = 'Email reset password dikirim ke $email.');
      }
    } catch (e) {
      if (mounted) setState(() => _pesan = 'Gagal mengirim email reset: $e');
    }
  }

  Future<void> _simpan() async {
    final nama = _namaC.text.trim();
    final email = _emailC.text.trim();
    final pass = _passC.text;

    if (nama.isEmpty) {
      setState(() => _pesan = 'Nama wajib diisi.');
      return;
    }
    if (_perluTim && (_tim == null || !_daftarTim.contains(_tim))) {
      setState(() => _pesan = 'Pilih tim dari daftar.');
      return;
    }
    if (!_edit && (email.isEmpty || pass.length < 6)) {
      setState(() =>
          _pesan = 'Email wajib diisi dan password minimal 6 karakter.');
      return;
    }

    setState(() {
      _busy = true;
      _pesan = null;
    });

    final db = FirebaseFirestore.instance;
    FirebaseApp? appKu;
    try {
      if (_edit) {
        final dulu = widget.data?['is_active'] != false;
        await db.collection('users').doc(widget.uid).update({
          'nama': nama,
          'role': _role,
          'tim': _perluTim ? _tim : FieldValue.delete(),
          'is_active': _aktif,
        });
        if (dulu && !_aktif) await _bersihkanAkun(widget.uid!);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Akun $nama diperbarui.')));
          Navigator.pop(context);
        }
        return;
      }

      // Buat akun baru lewat aplikasi kedua, agar admin tidak ikut logout
      FirebaseApp app;
      try {
        app = Firebase.app('akunBaru');
      } catch (_) {
        app = await Firebase.initializeApp(
            name: 'akunBaru', options: Firebase.app().options);
      }
      appKu = app;
      final auth = FirebaseAuth.instanceFor(app: app);
      final cred = await auth.createUserWithEmailAndPassword(
          email: email, password: pass);
      await db.collection('users').doc(cred.user!.uid).set({
        'email': email,
        'nama': nama,
        'role': _role,
        if (_perluTim) 'tim': _tim,
        'is_active': _aktif,
      });
      await auth.signOut();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Akun $nama berhasil dibuat.')));
        Navigator.pop(context);
      }
    } on FirebaseAuthException catch (e) {
      String m = 'Gagal membuat akun (${e.code}).';
      if (e.code == 'email-already-in-use') {
        m = 'Email sudah terdaftar di Firebase Authentication. Pakai email lain.';
      }
      if (e.code == 'invalid-email') m = 'Format email tidak valid.';
      if (e.code == 'weak-password') m = 'Password terlalu lemah.';
      if (mounted) setState(() => _pesan = m);
    } catch (e) {
      if (mounted) setState(() => _pesan = 'Gagal: $e');
    } finally {
      try {
        await appKu?.delete();
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sukses = _pesan != null && _pesan!.startsWith('Email reset');
    return Scaffold(
      appBar: _appBarBps(_edit ? 'Edit Akun' : 'Tambah Akun', []),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: _dek('Peran', Icons.badge_outlined),
            items: [
              const DropdownMenuItem(value: 'pegawai', child: Text('Pegawai')),
              const DropdownMenuItem(
                  value: 'kepala_tim', child: Text('Kepala Tim')),
              const DropdownMenuItem(
                  value: 'pimpinan', child: Text('Kepala BPS')),
              if (_akunAdmin)
                const DropdownMenuItem(value: 'admin', child: Text('Admin')),
            ],
            onChanged: (_edit && _akunAdmin)
                ? null
                : (v) => setState(() => _role = v ?? 'pegawai'),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: _namaC,
              decoration: _dek('Nama', Icons.person_outline)),
          const SizedBox(height: 12),
          TextField(
            controller: _emailC,
            enabled: !_edit,
            keyboardType: TextInputType.emailAddress,
            decoration: _dek('Email', Icons.email_outlined),
          ),
          if (!_edit) ...[
            const SizedBox(height: 12),
            TextField(
                controller: _passC,
                decoration:
                    _dek('Password (min. 6 karakter)', Icons.lock_outline)),
          ],
          if (_perluTim) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _tim,
              hint: const Text('Pilih tim'),
              decoration: _dek('Tim', Icons.groups_outlined),
              items: _itemTim(),
              onChanged: (v) => setState(() => _tim = v),
            ),
          ],
          const SizedBox(height: 8),
          SwitchListTile(
            value: _aktif,
            activeTrackColor: _hijau,
            title: const Text('Akun aktif'),
            subtitle: Text(_aktif
                ? 'Bisa login dan ditracking'
                : 'Tidak bisa login dan tidak ditracking'),
            onChanged: _diriSendiri ? null : (v) => setState(() => _aktif = v),
          ),
          if (_edit) ...[
            const SizedBox(height: 4),
            const Text(
              'Email tidak bisa diubah dari aplikasi. Password hanya bisa direset lewat email.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            TextButton.icon(
              onPressed: _kirimResetPassword,
              icon: const Icon(Icons.lock_reset),
              label: const Text('Kirim email reset password'),
            ),
          ],
          if (_pesan != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_pesan!,
                  style: TextStyle(
                      color: sukses ? _hijau : Colors.red,
                      fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _busy ? null : _simpan,
              icon: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save),
              label: Text(_edit ? 'SIMPAN PERUBAHAN' : 'BUAT AKUN',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// DASHBOARD KEPALA TIM
// ==========================================
class KepalaTimPage extends StatelessWidget {
  const KepalaTimPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _profilSaya(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return Scaffold(
            appBar: _appBarBps('Kepala Tim', [_tombolKeluar(context)]),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        final tim = (snap.data!['tim'] as String?) ?? 'Tanpa Tim';
        return _DashTabs(
          judul: 'Kepala Tim $tim',
          actions: [_tombolKeluar(context)],
          tabs: const [
            'Tugas Saya',
            'Persetujuan',
            'Peta Tim',
            'Sedang Keluar',
            'Rekap',
          ],
          views: [
            const TugasSayaView(peran: 'kepala_tim'),
            _PersetujuanView(tim: tim, peranFilter: 'pegawai'),
            _PetaLive(tim: tim, hanyaPeran: 'pegawai'),
            _SedangKeluarView(tim: tim, hanyaPeran: 'pegawai'),
            _RekapView(tim: tim, hanyaPeran: 'pegawai'),
          ],
        );
      },
    );
  }
}

// ==========================================
// DASHBOARD KEPALA BPS
// ==========================================
class PimpinanPage extends StatelessWidget {
  const PimpinanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _DashTabs(
      judul: 'Dasbor Kepala BPS',
      actions: [_tombolKeluar(context)],
      tabs: const ['Persetujuan', 'Peta', 'Sedang Keluar', 'Rekap per Tim'],
      views: const [
        _PersetujuanView(),
        _PetaLive(),
        _SedangKeluarView(),
        _RekapView(kelompokTim: true),
      ],
    );
  }
}