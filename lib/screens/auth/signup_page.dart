import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pitwatch/screens/auth/login_page.dart';
import 'package:pitwatch/widgets/auth/auth_button.dart';
import 'package:pitwatch/widgets/auth/custom_text_field.dart';
import 'package:pitwatch/services/account_service.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({Key? key}) : super(key: key);

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final username = _usernameCtrl.text.trim();
    final firstName = _firstNameCtrl.text.trim();
    final lastName = _lastNameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final res = await AccountService.signup(
      username: username,
      email: email,
      password: password,
      firstName: firstName,
      lastName: lastName,
    );
    setState(() => _loading = false);
    if (res['success'] == true) {
      // show success then navigate to login
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account created — please log in')),
      );
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
    } else {
      final msg = res['message']?.toString() ?? 'Signup failed';
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Signup failed'),
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
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Column(
                        children: [
                          Text(
                            'Sign Up',
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
                          validator: (v) {
                            if (v == null || v.trim().isEmpty)
                              return 'Enter username';
                            if (v.trim().length < 3) return 'Too short';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 312,
                        height: 52,
                        child: CustomTextField(
                          label: "First name",
                          controller: _firstNameCtrl,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty)
                              return 'Enter first name';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 312,
                        height: 52,
                        child: CustomTextField(
                          label: "Last name",
                          controller: _lastNameCtrl,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty)
                              return 'Enter last name';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 312,
                        height: 52,
                        child: CustomTextField(
                          label: "Email",
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty)
                              return 'Enter email';
                            if (!v.contains('@')) return 'Invalid email';
                            return null;
                          },
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
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Enter password';
                            if (v.length < 6) return 'Min 6 chars';
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: 312,
                        height: 48,
                        child: AuthButton(
                          text: _loading ? 'Please wait...' : 'Create Account',
                          onPressed: _loading ? null : _submit,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Already have an account?',
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
                              builder: (context) => const LoginPage(),
                            ),
                          );
                        },
                        child: Text(
                          'Log in',
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
      ),
    );
  }
}
