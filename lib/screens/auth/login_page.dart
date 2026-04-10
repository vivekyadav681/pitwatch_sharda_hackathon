import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pitwatch/screens/auth/signup_page.dart';
import 'package:pitwatch/screens/home/main_screen.dart';
import 'package:pitwatch/widgets/auth/auth_button.dart';
import 'package:pitwatch/widgets/auth/custom_text_field.dart';
import 'package:pitwatch/services/account_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter username and password')),
      );
      return;
    }
    setState(() => _loading = true);
    final res = await AccountService.login(
      username: username,
      password: password,
    );
    setState(() => _loading = false);
    if (res['success'] == true) {
      // Debug: print stored tokens to console
      try {
        final prefs = await SharedPreferences.getInstance();
        final access = prefs.getString('access_token');
        final refresh = prefs.getString('refresh_token');
        final authPayload = prefs.getString('auth_payload');
        debugPrint('Login tokens: access_token=$access');
        debugPrint('Login tokens: refresh_token=$refresh');
        debugPrint('Login tokens: auth_payload=$authPayload');
      } catch (e) {
        debugPrint('Failed to read tokens after login: $e');
      }
      // fetch and cache user profile after successful login
      try {
        await AccountService.fetchProfile();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const MainScreen()),
      );
    } else {
      final msg = res['message']?.toString() ?? 'Login failed';
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Login failed'),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF172033), Color(0xFF1E356C)],
            stops: [0.0, 1.0],
            transform: GradientRotation(2.94), // 168.33deg in radians
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Card(
              color: Colors.transparent,
              shadowColor: Colors.transparent,
              margin: const EdgeInsets.symmetric(horizontal: 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Column(
                      children: [
                        Text(
                          'Log In',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 36,
                            height: 1.0,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'AI road surveillance',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.goldman(
                            color: const Color(0xFF9CA3AF),
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 15 / 16,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),
                    SizedBox(
                      width: 312,
                      height: 52,
                      child: CustomTextField(
                        label: "Username",
                        controller: _usernameCtrl,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.next,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: 312,
                      height: 52,
                      child: CustomTextField(
                        label: "Password",
                        controller: _passwordCtrl,
                        obscureText: true,
                        showObscureToggle: true,
                        textInputAction: TextInputAction.done,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: 312,
                      height: 48,
                      child: AuthButton(
                        text: _loading ? 'Please wait...' : 'Continue',
                        onPressed: _loading ? null : _submit,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Sign up with another?',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        color: const Color(0xFF9CA3AF),
                        fontWeight: FontWeight.w400,
                        fontSize: 13,
                        height: 1.0,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const SignupPage(),
                          ),
                        );
                      },
                      child: Text(
                        'Sign Up',
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
