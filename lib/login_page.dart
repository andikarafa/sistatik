import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'main.dart';

class LoginPage extends StatefulWidget {
  /// Pesan yang ditampilkan di bawah form (misalnya akun dinonaktifkan).
  final String? pesan;
  const LoginPage({super.key, this.pesan});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailC = TextEditingController();
  final _passC = TextEditingController();
  bool _loading = false;
  bool _hidePass = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.pesan;
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 1. Login
      final cred = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
            email: _emailC.text.trim(),
            password: _passC.text,
          )
          .timeout(const Duration(seconds: 20));

      // 2. Baca peran dari Firestore
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(cred.user!.uid)
          .get()
          .timeout(const Duration(seconds: 20));

      final data = doc.data();

      // 3. Tolak akun yang dinonaktifkan admin
      if (data?['is_active'] == false) {
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          setState(() =>
              _error = 'Akun Anda sudah dinonaktifkan. Hubungi admin.');
        }
        return;
      }

      final role = data?['role'];
      if (!mounted) return;

      // 4. Arahkan sesuai peran
      if (role == 'admin') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AdminDashboardLivePage()),
        );
      } else if (role == 'pegawai') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PegawaiHomePage()),
        );
      } else if (role == 'pimpinan') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PimpinanPage()),
        );
      } else if (role == 'kepala_tim') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
              builder: (_) => const PegawaiHomePage(peran: 'kepala_tim')),
        );
      } else {
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          setState(() => _error = 'Peran akun belum diatur di Firestore.');
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _error = 'Gagal login (${e.code}): ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailC.dispose();
    _passC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const biruTua = Color(0xFF1478A8);
    const biru = Color(0xFF1E8CC0);
    const biruMuda = Color(0xFF29ABE2);
    const oranye = Color(0xFFF58634);
    const hijau = Color(0xFF6DBE4B);

    return Scaffold(
      body: Stack(
        children: [
          // Latar gradasi biru BPS
          Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [biruTua, biruMuda, Color(0xFFEAF7FD)],
                stops: [0.0, 0.5, 0.95],
              ),
            ),
          ),
          // Hiasan lingkaran warna logo
          Positioned(
            top: -60,
            right: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: oranye.withAlpha(90),
              ),
            ),
          ),
          Positioned(
            top: 110,
            left: -70,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hijau.withAlpha(80),
              ),
            ),
          ),
          Positioned(
            bottom: -70,
            left: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: biruMuda.withAlpha(60),
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            right: -60,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: oranye.withAlpha(50),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(blurRadius: 16, color: Colors.black26)
                        ],
                      ),
                      child: Image.asset('assets/logo_bps.png', height: 110),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'MONITORING PEGAWAI',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 1.5,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black45)],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Badan Pusat Statistik',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black45)],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      elevation: 10,
                      clipBehavior: Clip.antiAlias,
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      child: Column(
                        children: [
                          // Garis tiga warna logo
                          const Row(
                            children: [
                              Expanded(
                                  child: SizedBox(
                                      height: 7,
                                      child: ColoredBox(color: biruMuda))),
                              Expanded(
                                  child: SizedBox(
                                      height: 7,
                                      child: ColoredBox(color: oranye))),
                              Expanded(
                                  child: SizedBox(
                                      height: 7,
                                      child: ColoredBox(color: hijau))),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              children: [
                                const Text(
                                  'Masuk ke Akun',
                                  style: TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.bold,
                                      color: biru),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _emailC,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: const Icon(Icons.email_outlined,
                                        color: biruMuda),
                                    filled: true,
                                    fillColor: const Color(0xFFF1F9FD),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide.none),
                                    focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(
                                            color: biruMuda, width: 2)),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                TextField(
                                  controller: _passC,
                                  obscureText: _hidePass,
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: const Icon(Icons.lock_outline,
                                        color: hijau),
                                    filled: true,
                                    fillColor: const Color(0xFFF3FAF0),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide.none),
                                    focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(
                                            color: hijau, width: 2)),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                          _hidePass
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                          color: Colors.grey),
                                      onPressed: () => setState(
                                          () => _hidePass = !_hidePass),
                                    ),
                                  ),
                                ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(_error!,
                                        textAlign: TextAlign.center,
                                        style:
                                            const TextStyle(color: Colors.red)),
                                  ),
                                const SizedBox(height: 20),
                                SizedBox(
                                  width: double.infinity,
                                  height: 52,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: oranye,
                                      foregroundColor: Colors.white,
                                      elevation: 4,
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(14)),
                                    ),
                                    onPressed: _loading ? null : _login,
                                    child: _loading
                                        ? const SizedBox(
                                            height: 24,
                                            width: 24,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white),
                                          )
                                        : const Text('MASUK',
                                            style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.5)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Sistem Monitoring Pegawai',
                      style: TextStyle(
                          fontSize: 12,
                          color: biruTua,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}