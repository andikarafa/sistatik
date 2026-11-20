part of 'main.dart';

// ==========================================
// KONFIGURASI FIREBASE (BAWAAN + KUSTOM)
// Untuk pindah project secara permanen, ganti nilai di bawah ini
// lalu pasang APK baru.
// ==========================================
const FirebaseOptions _opsiBawaan = FirebaseOptions(
  apiKey: "AIzaSyD5g6IQG7PG3P-wuvnqPCiFlWWs99BmaQ0",
  appId: "1:303319621575:android:fda4ed70dd95b8d6db83e2",
  messagingSenderId: "303319621575",
  projectId: "monitoring-bps",
  authDomain: "monitoring-bps.firebaseapp.com",
  storageBucket: "monitoring-bps.appspot.com",
  measurementId: "G-05TR8Y4284",
);

const String _kunciPrefs = 'firebase_opsi_kustom';

FirebaseOptions _opsiDariMap(Map<String, dynamic> m) {
  final pid = (m['projectId'] ?? '').toString();
  final sb = (m['storageBucket'] ?? '').toString();
  return FirebaseOptions(
    apiKey: (m['apiKey'] ?? '').toString(),
    appId: (m['appId'] ?? '').toString(),
    messagingSenderId: (m['messagingSenderId'] ?? '').toString(),
    projectId: pid,
    authDomain: '$pid.firebaseapp.com',
    storageBucket: sb.isEmpty ? null : sb,
  );
}

Future<FirebaseOptions> _opsiFirebase() async {
  try {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kunciPrefs);
    if (s != null) {
      return _opsiDariMap(jsonDecode(s) as Map<String, dynamic>);
    }
  } catch (_) {}
  return _opsiBawaan;
}

// Baca isi google-services.json -> isian konfigurasi
Map<String, String>? _bacaGoogleServices(String teks) {
  try {
    final j = jsonDecode(teks) as Map<String, dynamic>;
    final info = j['project_info'] as Map<String, dynamic>;
    final klien = (j['client'] as List).cast<Map<String, dynamic>>();
    var pilih = klien.first;
    for (final c in klien) {
      final pkg = ((c['client_info'] as Map)['android_client_info']
          as Map)['package_name'];
      if (pkg == 'id.go.bps.sistatik') {
        pilih = c;
        break;
      }
    }
    return {
      'apiKey':
          ((pilih['api_key'] as List).first as Map)['current_key'].toString(),
      'appId': (pilih['client_info'] as Map)['mobilesdk_app_id'].toString(),
      'messagingSenderId': info['project_number'].toString(),
      'projectId': info['project_id'].toString(),
      'storageBucket': (info['storage_bucket'] ?? '').toString(),
    };
  } catch (_) {
    return null;
  }
}

// ---------- Konversi data Firestore <-> JSON ----------
dynamic _kePolos(dynamic v) {
  if (v is Timestamp) return {'__ts': v.millisecondsSinceEpoch};
  if (v is Map) return v.map((k, x) => MapEntry(k.toString(), _kePolos(x)));
  if (v is List) return v.map(_kePolos).toList();
  return v;
}

dynamic _dariPolos(dynamic v) {
  if (v is Map) {
    if (v.length == 1 && v.containsKey('__ts')) {
      return Timestamp.fromMillisecondsSinceEpoch((v['__ts'] as num).toInt());
    }
    return v.map((k, x) => MapEntry(k.toString(), _dariPolos(x)));
  }
  if (v is List) return v.map(_dariPolos).toList();
  return v;
}

// ==========================================
// REKAP ADMIN + TOMBOL UNDUH EXCEL
// ==========================================
class _RekapAdminView extends StatefulWidget {
  const _RekapAdminView();

  @override
  State<_RekapAdminView> createState() => _RekapAdminViewState();
}

class _RekapAdminViewState extends State<_RekapAdminView> {
  bool _sibuk = false;

  void _pesan(String t) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _unduh() async {
    final hr = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(
        start: DateTime.now().subtract(const Duration(days: 6)),
        end: DateTime.now(),
      ),
      helpText: 'Pilih rentang tanggal rekap',
    );
    if (hr == null) return;
    setState(() => _sibuk = true);
    try {
      final a = _tanggalStr(hr.start);
      final b = _tanggalStr(hr.end);
      final snap = await _logCol
          .where('tanggal', isGreaterThanOrEqualTo: a)
          .where('tanggal', isLessThanOrEqualTo: b)
          .get();
      final rows = snap.docs
          .map((d) => d.data() as Map<String, dynamic>)
          .toList()
        ..sort((x, y) {
          final c = (x['tanggal'] ?? '')
              .toString()
              .compareTo((y['tanggal'] ?? '').toString());
          if (c != 0) return c;
          final p = (x['jamKeluar'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
          final q = (y['jamKeluar'] as Timestamp?)?.millisecondsSinceEpoch ?? 0;
          return p.compareTo(q);
        });
      if (rows.isEmpty) {
        if (mounted) _pesan('Tidak ada data pada rentang itu.');
        return;
      }

      final ex = xl.Excel.createExcel();
      final sheet = ex['Sheet1'];
      sheet.appendRow([
        xl.TextCellValue('Tanggal'),
        xl.TextCellValue('Nama'),
        xl.TextCellValue('Jabatan'),
        xl.TextCellValue('Tim'),
        xl.TextCellValue('Keterangan di luar'),
        xl.TextCellValue('Status izin'),
        xl.TextCellValue('Jam keluar'),
        xl.TextCellValue('Jam kembali'),
        xl.TextCellValue('Lama di luar (menit)'),
      ]);
      for (final m in rows) {
        final keluar = m['jamKeluar'] as Timestamp?;
        final kembali = m['jamKembali'] as Timestamp?;
        final lama = (keluar != null && kembali != null)
            ? kembali.toDate().difference(keluar.toDate()).inMinutes
            : null;
        sheet.appendRow([
          xl.TextCellValue(_tglTampil((m['tanggal'] ?? '').toString())),
          xl.TextCellValue((m['nama'] ?? '-').toString()),
          xl.TextCellValue(_labelPeran[m['peran']] ?? 'Pegawai'),
          xl.TextCellValue((m['tim'] ?? '-').toString()),
          xl.TextCellValue((m['keterangan'] ?? '-').toString()),
          xl.TextCellValue(m['izin'] == false ? 'Tanpa izin' : 'Izin'),
          xl.TextCellValue(_fmtTs(keluar)),
          xl.TextCellValue(kembali == null ? 'Belum kembali' : _fmtTs(kembali)),
          lama == null ? xl.TextCellValue('') : xl.IntCellValue(lama),
        ]);
      }

      final bytes = ex.encode();
      if (bytes == null) {
        if (mounted) _pesan('Gagal membuat file Excel.');
        return;
      }
      await FileSaver.instance.saveAs(
        name: 'Rekap_SISTATIK_${a}_sd_$b',
        bytes: Uint8List.fromList(bytes),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (mounted) _pesan('${rows.length} baris diekspor.');
    } catch (e) {
      if (mounted) _pesan('Gagal mengunduh: $e');
    } finally {
      if (mounted) setState(() => _sibuk = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _sibuk ? null : _unduh,
              style: ElevatedButton.styleFrom(backgroundColor: _hijau),
              icon: _sibuk
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download),
              label: const Text('UNDUH EXCEL (PILIH RENTANG TANGGAL)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
        const Expanded(child: _RekapView()),
      ],
    );
  }
}

// ==========================================
// MENU DATABASE: BACKUP, RESTORE, GANTI KONEKSI
// ==========================================
class _DatabaseView extends StatefulWidget {
  const _DatabaseView();

  @override
  State<_DatabaseView> createState() => _DatabaseViewState();
}

class _DatabaseViewState extends State<_DatabaseView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _jsonC = TextEditingController();
  final _apiC = TextEditingController();
  final _appC = TextEditingController();
  final _projC = TextEditingController();
  final _senderC = TextEditingController();
  final _bucketC = TextEditingController();
  final _passC = TextEditingController();

  bool _sibuk = false;
  bool _keBaru = false;
  String? _namaFile;
  Map<String, dynamic>? _isi;
  String? _tersimpan; // projectId kustom yang tersimpan
  final List<String> _log = [];

  static const _koleksiBackup = ['users', 'pengaturan', 'log_keluar'];

  @override
  void initState() {
    super.initState();
    _muatTersimpan();
  }

  @override
  void dispose() {
    for (final c in [_jsonC, _apiC, _appC, _projC, _senderC, _bucketC, _passC]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _muatTersimpan() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_kunciPrefs);
      if (s != null) {
        final m = jsonDecode(s) as Map<String, dynamic>;
        _tersimpan = (m['projectId'] ?? '').toString();
      } else {
        _tersimpan = null;
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _pesan(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  void _tulis(String t) {
    if (mounted) setState(() => _log.add(t));
  }

  InputDecoration _dek(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      );

  Widget _kartu(String judul, List<Widget> anak) => Card(
        elevation: 3,
        margin: const EdgeInsets.only(bottom: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(judul,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: _biru)),
              const SizedBox(height: 10),
              ...anak,
            ],
          ),
        ),
      );

  Widget _tombol(String teks, IconData ikon, VoidCallback? aksi,
          {Color? warna}) =>
      SizedBox(
        width: double.infinity,
        height: 46,
        child: ElevatedButton.icon(
          onPressed: _sibuk ? null : aksi,
          style: warna == null
              ? null
              : ElevatedButton.styleFrom(backgroundColor: warna),
          icon: Icon(ikon),
          label: Text(teks, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      );

  // ---------- Konfigurasi form ----------
  void _isiOtomatis() {
    final m = _bacaGoogleServices(_jsonC.text.trim());
    if (m == null) {
      _pesan('Isi google-services.json tidak terbaca.');
      return;
    }
    setState(() {
      _apiC.text = m['apiKey']!;
      _appC.text = m['appId']!;
      _projC.text = m['projectId']!;
      _senderC.text = m['messagingSenderId']!;
      _bucketC.text = m['storageBucket']!;
    });
    _pesan('Terisi: project ${m['projectId']}');
  }

  FirebaseOptions? _opsiDariForm() {
    if (_apiC.text.trim().isEmpty ||
        _appC.text.trim().isEmpty ||
        _projC.text.trim().isEmpty) {
      return null;
    }
    return _opsiDariMap({
      'apiKey': _apiC.text.trim(),
      'appId': _appC.text.trim(),
      'messagingSenderId': _senderC.text.trim(),
      'projectId': _projC.text.trim(),
      'storageBucket': _bucketC.text.trim(),
    });
  }

  // Mengembalikan null jika koneksi baik, atau teks masalahnya.
  // Hanya memeriksa Authentication. Firestore sengaja TIDAK disentuh di sini
  // karena sisa sambungan Firestore dari aplikasi sementara yang sudah
  // dihapus menyebabkan error "FirebaseApp was deleted" saat restore.
  Future<String?> _uji(FirebaseOptions o) async {
    FirebaseApp? app;
    try {
      app = await Firebase.initializeApp(
          name: 'uji${DateTime.now().millisecondsSinceEpoch}', options: o);
      final auth = FirebaseAuth.instanceFor(app: app);
      try {
        await auth
            .signInWithEmailAndPassword(
                email: 'uji@uji.invalid', password: 'uji-uji-123')
            .timeout(const Duration(seconds: 20));
      } on FirebaseAuthException catch (e) {
        if (e.code == 'operation-not-allowed') {
          return 'Email/Password belum diaktifkan di Authentication project itu.';
        }
        const baik = [
          'user-not-found',
          'invalid-credential',
          'wrong-password',
          'invalid-email'
        ];
        if (!baik.contains(e.code)) return 'Authentication gagal (${e.code}).';
      }
      return null;
    } catch (e) {
      return 'Tidak bisa terhubung: $e';
    } finally {
      try {
        await app?.delete();
      } catch (_) {}
    }
  }

  Future<void> _ujiKoneksi() async {
    final o = _opsiDariForm();
    if (o == null) {
      _pesan('Isi konfigurasi dulu.');
      return;
    }
    setState(() => _sibuk = true);
    final hasil = await _uji(o);
    if (mounted) setState(() => _sibuk = false);
    _pesan(hasil ??
        'Koneksi ke project ${o.projectId} BERHASIL (Authentication). Firestore diperiksa saat restore.');
  }

  Future<void> _simpanKoneksi() async {
    final o = _opsiDariForm();
    if (o == null) {
      _pesan('Isi konfigurasi dulu.');
      return;
    }
    setState(() => _sibuk = true);
    final hasil = await _uji(o);
    if (!mounted) return;
    if (hasil != null) {
      setState(() => _sibuk = false);
      _pesan(hasil);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pindah koneksi?'),
        content: Text(
            'Aplikasi di HP ini akan memakai project "${o.projectId}" setelah ditutup dan dibuka lagi. Anda harus login ulang dengan akun yang ada di project itu.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Simpan')),
        ],
      ),
    );
    if (ok == true) {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kunciPrefs,
          jsonEncode({
            'apiKey': o.apiKey,
            'appId': o.appId,
            'messagingSenderId': o.messagingSenderId,
            'projectId': o.projectId,
            'storageBucket': o.storageBucket ?? '',
          }));
      await _muatTersimpan();
      _pesan('Tersimpan. Tutup aplikasi sepenuhnya, lalu buka lagi.');
    }
    if (mounted) setState(() => _sibuk = false);
  }

  Future<void> _kembaliBawaan() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kunciPrefs);
    await _muatTersimpan();
    _pesan('Dikembalikan ke bawaan. Tutup lalu buka aplikasi lagi.');
  }

  // ---------- BACKUP ----------
  Future<void> _backup() async {
    setState(() {
      _sibuk = true;
      _log.clear();
    });
    try {
      final db = FirebaseFirestore.instance;
      final kol = <String, dynamic>{};
      for (final k in _koleksiBackup) {
        final s = await db.collection(k).get();
        kol[k] = s.docs
            .map((d) => {'id': d.id, 'data': _kePolos(d.data())})
            .toList();
        _tulis('$k: ${s.docs.length} dokumen');
      }
      final out = {
        'versi': 1,
        'dibuat': DateTime.now().toIso8601String(),
        'project': Firebase.app().options.projectId,
        'koleksi': kol,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(out)));
      await FileSaver.instance.saveAs(
        name: 'Backup_SISTATIK_${_tanggalStr(DateTime.now())}',
        bytes: bytes,
        fileExtension: 'json',
        mimeType: MimeType.json,
      );
      _tulis('Backup selesai. Simpan file ini di tempat aman.');
    } catch (e) {
      _tulis('Backup gagal: $e');
    } finally {
      if (mounted) setState(() => _sibuk = false);
    }
  }

  // ---------- RESTORE ----------
  Future<void> _pilihFile() async {
    try {
      final f = await FilePicker.pickFile();
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['koleksi'] == null) {
        _pesan('Bukan file backup SISTATIK.');
        return;
      }
      final kol = m['koleksi'] as Map;
      if (!mounted) return;
      setState(() {
        _isi = m;
        _namaFile = f.name;
        _log
          ..clear()
          ..add('File: ${f.name}')
          ..add('Berasal dari project: ${m['project']}')
          ..add(
              'Isi: ${(kol['users'] as List?)?.length ?? 0} akun, ${(kol['log_keluar'] as List?)?.length ?? 0} catatan keluar');
      });
    } catch (e) {
      _pesan('File tidak bisa dibaca: $e');
    }
  }

  Future<void> _pulihkan() async {
    final isi = _isi;
    if (isi == null) {
      _pesan('Pilih file backup dulu.');
      return;
    }
    FirebaseOptions target;
    if (_keBaru) {
      final o = _opsiDariForm();
      if (o == null) {
        _pesan('Isi konfigurasi project tujuan dulu.');
        return;
      }
      target = o;
    } else {
      target = Firebase.app().options;
    }
    final beda = target.projectId != Firebase.app().options.projectId;
    final pass = _passC.text;
    if (beda && pass.length < 6) {
      _pesan('Password sementara minimal 6 karakter.');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mulai pemulihan?'),
        content: Text(
            'Data dari file akan ditulis ke project "${target.projectId}". Dokumen dengan ID yang sama akan ditimpa.'
            '${beda ? '\n\nSemua akun dibuat ulang di project tujuan dengan password sementara yang Anda isi.' : ''}'
            '\n\nPastikan Rules Firestore project tujuan sedang dalam mode terbuka sementara.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mulai')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _sibuk = true);
    try {
      FirebaseApp? app;
      if (beda) {
        // Koneksi ini sengaja tidak ditutup paksa setelah selesai.
        app = await Firebase.initializeApp(
            name: 'migrasi${DateTime.now().millisecondsSinceEpoch}',
            options: target);
      }
      final db = app == null
          ? FirebaseFirestore.instance
          : FirebaseFirestore.instanceFor(app: app);

      final kol = (isi['koleksi'] as Map).cast<String, dynamic>();
      List<Map<String, dynamic>> ambil(String k) => ((kol[k] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final users = ambil('users');
      final peta = <String, String>{}; // uid lama -> uid baru

      if (beda) {
        final auth = FirebaseAuth.instanceFor(app: app!);
        for (final u in users) {
          final lama = u['id'].toString();
          final data = Map<String, dynamic>.from(u['data'] as Map);
          final email = (data['email'] ?? '').toString();
          if (email.isEmpty) {
            _tulis('Dilewati (tanpa email): ${data['nama'] ?? lama}');
            continue;
          }
          String? baru;
          try {
            final c = await auth.createUserWithEmailAndPassword(
                email: email, password: pass);
            baru = c.user!.uid;
          } on FirebaseAuthException catch (e) {
            if (e.code == 'email-already-in-use') {
              try {
                final c = await auth.signInWithEmailAndPassword(
                    email: email, password: pass);
                baru = c.user!.uid;
              } catch (_) {}
            } else {
              _tulis('Gagal membuat akun $email (${e.code})');
            }
          }
          try {
            await auth.signOut();
          } catch (_) {}
          if (baru != null) {
            peta[lama] = baru;
            _tulis('Akun siap: $email');
          } else {
            _tulis(
                'Akun dilewati: $email (sudah ada dengan password berbeda?)');
          }
        }
      }

      final tulis = <MapEntry<DocumentReference, Map<String, dynamic>>>[];
      for (final u in users) {
        final lama = u['id'].toString();
        final id = beda ? peta[lama] : lama;
        if (id == null) continue;
        tulis.add(MapEntry(
            db.collection('users').doc(id),
            Map<String, dynamic>.from(_dariPolos(u['data']) as Map)));
      }
      for (final d in ambil('pengaturan')) {
        tulis.add(MapEntry(
            db.collection('pengaturan').doc(d['id'].toString()),
            Map<String, dynamic>.from(_dariPolos(d['data']) as Map)));
      }
      for (final d in ambil('log_keluar')) {
        final data = Map<String, dynamic>.from(_dariPolos(d['data']) as Map);
        final lamaUid = (data['uid'] ?? '').toString();
        data['uid'] = peta[lamaUid] ?? lamaUid;
        tulis.add(MapEntry(
            db.collection('log_keluar').doc(d['id'].toString()), data));
      }

      _tulis('Menulis ${tulis.length} dokumen...');
      for (var i = 0; i < tulis.length; i += 400) {
        final b = db.batch();
        for (final t in tulis.skip(i).take(400)) {
          b.set(t.key, t.value);
        }
        await b.commit();
      }
      _tulis(
          'SELESAI. ${tulis.length} dokumen dipulihkan ke ${target.projectId}.');
      if (beda) {
        _tulis(
            'Langkah berikut: simpan koneksi ke project tujuan, buka ulang aplikasi, login dengan email lama dan password sementara.');
      }
    } on FirebaseException catch (e) {
      _tulis(e.code == 'permission-denied'
          ? 'DITOLAK oleh Rules. Ubah Rules project tujuan ke mode terbuka sementara, lalu ulangi.'
          : 'Gagal (${e.code}): ${e.message}');
    } catch (e) {
      _tulis('Gagal: $e');
    } finally {
      if (mounted) setState(() => _sibuk = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final aktif = Firebase.app().options.projectId;
    final belumPindah = _tersimpan != null && _tersimpan != aktif;

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _kartu('Project terhubung', [
          _barisInfo(Icons.cloud_done_outlined, 'Sedang terhubung ke', aktif),
          _barisInfo(
              Icons.save_outlined,
              'Koneksi tersimpan untuk dibuka berikutnya',
              _tersimpan ?? 'Bawaan aplikasi'),
          if (belumPindah)
            const Text(
              'Tersimpan, tetapi aplikasi belum berpindah. Tutup aplikasi sepenuhnya lalu buka lagi. Jika setelah itu masih sama, ganti nilai _opsiBawaan lalu pasang APK baru.',
              style: TextStyle(color: Colors.red, fontSize: 12),
            ),
        ]),
        _kartu('1. Backup data', [
          const Text(
              'Menyimpan akun, pengaturan jam kantor, dan seluruh catatan keluar kantor ke satu file .json. Password tidak ikut tersimpan karena Firebase tidak mengizinkannya.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 10),
          _tombol('BUAT BACKUP', Icons.backup, _backup),
        ]),
        _kartu('2. Konfigurasi project tujuan (baru)', [
          const Text(
              'Tempel isi google-services.json dari project baru, lalu tekan Isi Otomatis.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          TextField(
              controller: _jsonC,
              maxLines: 3,
              decoration: _dek('Isi google-services.json')),
          const SizedBox(height: 8),
          _tombol('ISI OTOMATIS', Icons.auto_fix_high, _isiOtomatis),
          const SizedBox(height: 10),
          TextField(controller: _apiC, decoration: _dek('apiKey')),
          const SizedBox(height: 8),
          TextField(controller: _appC, decoration: _dek('appId')),
          const SizedBox(height: 8),
          TextField(controller: _projC, decoration: _dek('projectId')),
          const SizedBox(height: 8),
          TextField(
              controller: _senderC, decoration: _dek('messagingSenderId')),
          const SizedBox(height: 8),
          TextField(controller: _bucketC, decoration: _dek('storageBucket')),
          const SizedBox(height: 10),
          _tombol('UJI KONEKSI', Icons.wifi_tethering, _ujiKoneksi),
          const SizedBox(height: 8),
          _tombol(
              'SIMPAN & PAKAI KONEKSI INI', Icons.swap_horiz, _simpanKoneksi,
              warna: _biru),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _sibuk ? null : _kembaliBawaan,
            icon: const Icon(Icons.restore),
            label: const Text('Kembalikan ke koneksi bawaan'),
          ),
        ]),
        _kartu('3. Restore data', [
          _tombol('PILIH FILE BACKUP', Icons.folder_open, _pilihFile),
          if (_namaFile != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Dipilih: $_namaFile',
                  style: const TextStyle(fontSize: 12)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _keBaru,
            activeTrackColor: _hijau,
            title: const Text('Pulihkan ke project baru (kartu 2)'),
            subtitle: Text(_keBaru
                ? 'Akun dibuat ulang di project tujuan'
                : 'Ke project yang sedang terhubung'),
            onChanged: (v) => setState(() => _keBaru = v),
          ),
          if (_keBaru) ...[
            TextField(
                controller: _passC,
                decoration:
                    _dek('Password sementara untuk semua akun (min. 6)')),
            const SizedBox(height: 10),
          ],
          _tombol('PULIHKAN DATA', Icons.settings_backup_restore, _pulihkan,
              warna: Colors.red),
        ]),
        if (_sibuk) const LinearProgressIndicator(),
        if (_log.isNotEmpty)
          _kartu('Catatan proses', [
            for (final l in _log)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(l, style: const TextStyle(fontSize: 12)),
              ),
          ]),
      ],
    );
  }
}