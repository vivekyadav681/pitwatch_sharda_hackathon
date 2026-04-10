import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'dart:convert';

import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/screens/auth/signup_page.dart';
import 'package:pitwatch/services/account_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _name = 'User';
  String _email = '';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _dumpPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().toList()..sort();

      final buffer = StringBuffer();
      buffer.writeln('--- SharedPreferences dump start ---');

      for (final k in keys) {
        final v = prefs.get(k);
        String valueStr;
        try {
          if (v is String) {
            // try to pretty-print JSON strings
            final decoded = json.decode(v);
            valueStr = const JsonEncoder.withIndent('  ').convert(decoded);
          } else {
            valueStr = v == null ? 'null' : v.toString();
          }
        } catch (_) {
          valueStr = v == null ? 'null' : v.toString();
        }

        // Log to console and add a nicely spaced entry to buffer
        debugPrint('$k: $valueStr');
        buffer.writeln('$k:');
        // indent multi-line values for readability
        for (final line in valueStr.split('\n')) {
          buffer.writeln('  $line');
        }
        buffer.writeln();
      }

      buffer.writeln('--- SharedPreferences dump end ---');
      final contentStr = buffer.toString();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SharedPreferences dumped to console')),
      );

      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('SharedPreferences'),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 400.h, maxWidth: 300.w),
            child: SingleChildScrollView(
              child: SelectableText(
                contentStr.isNotEmpty ? contentStr : '(empty)',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Failed to dump prefs: $e');
    }
  }

  Future<void> _loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user_profile');
      if (raw == null || raw.isEmpty) return;
      final jsonBody = json.decode(raw);
      if (jsonBody is Map<String, dynamic>) {
        String name = '';
        final first = jsonBody['first_name']?.toString();
        final last = jsonBody['last_name']?.toString();
        if ((first?.isNotEmpty ?? false) || (last?.isNotEmpty ?? false)) {
          name = '${first ?? ''} ${last ?? ''}'.trim();
        } else if (jsonBody['name'] != null) {
          name = jsonBody['name'].toString();
        } else if (jsonBody['username'] != null) {
          name = jsonBody['username'].toString();
        }

        final email = jsonBody['email']?.toString() ?? '';
        setState(() {
          _name = name.isNotEmpty ? name : 'User';
          _email = email;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        /// TOP GRADIENT (same as HomeScreen)
        Container(
          width: double.infinity,
          height: 150.h,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1, -0.5),
              end: Alignment(1, 1),
              colors: [Color(0xFF1E3A8A), Color(0xFF3470DA)],
            ),
          ),
        ),

        SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
                  child: Text(
                    "Profile",
                    style: GoogleFonts.inter(
                      fontSize: 28.sp,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),

                // Info card overlapping the gradient
                Center(
                  child: Transform.translate(
                    offset: Offset(0, 0.h),
                    child: InfoBannerCard(name: _name, email: _email),
                  ),
                ),

                SizedBox(height: 12.h),

                // Action cards
                Column(
                  children: [
                    ActionCard(
                      text: 'Send Feedback',
                      icon: Icons.chat_bubble_outline,
                      onTap: () {},
                    ),
                    SizedBox(height: 16.h),
                    ActionCard(
                      text: 'Share App',
                      icon: Icons.share,
                      onTap: () {},
                    ),
                    SizedBox(height: 16.h),
                    ActionCard(
                      text: 'Log Out',
                      icon: Icons.logout_outlined,
                      onTap: () async {
                        // show progress dialog
                        showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (ctx) =>
                              const Center(child: CircularProgressIndicator()),
                        );
                        final res = await AccountService.logout();
                        if (Navigator.canPop(context))
                          Navigator.of(context).pop();
                        // navigate to signup regardless; show error if logout failed
                        if (res['success'] == true) {
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(
                              builder: (_) => const SignupPage(),
                            ),
                            (route) => false,
                          );
                        } else {
                          // show error then navigate to signup
                          if (res['message'] != null) {
                            showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Logout'),
                                content: Text(res['message'].toString()),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: const Text('OK'),
                                  ),
                                ],
                              ),
                            );
                          }
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(
                              builder: (_) => const SignupPage(),
                            ),
                            (route) => false,
                          );
                        }
                      },
                    ),
                    SizedBox(height: 16.h),
                    ActionCard(
                      text: 'Dump SharedPrefs',
                      icon: Icons.storage_outlined,
                      onTap: () async {
                        await _dumpPrefs();
                      },
                    ),
                  ],
                ),

                Expanded(child: Container()),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class InfoBannerCard extends StatelessWidget {
  final String name;
  final String email;

  const InfoBannerCard({super.key, required this.name, required this.email});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 312.w,
      height: 77.h,
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 12.h),
      decoration: BoxDecoration(
        color: const Color.fromRGBO(255, 255, 255, 1),
        borderRadius: BorderRadius.circular(16.r),
        boxShadow: [
          BoxShadow(
            color: const Color.fromRGBO(0, 0, 0, 0.25),
            offset: Offset(0, 13.h),
            blurRadius: 24.8.r,
            spreadRadius: -5,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Name
          Text(
            name,
            style: GoogleFonts.inter(
              fontSize: 24.sp,
              fontWeight: FontWeight.w600,
              height: 20 / 24, // line-height control
              letterSpacing: 0,
              color: const Color(0xFF1E3A8A),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),

          SizedBox(height: 4.h),

          // Email / secondary text
          Text(
            email,
            style: GoogleFonts.inter(
              fontSize: 14.sp,
              fontWeight: FontWeight.w400,
              height: 20 / 14,
              letterSpacing: 0,
              color: const Color(0xFF64748B),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class ActionCard extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback? onTap;

  const ActionCard({
    super.key,
    required this.text,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 312.w,
        height: 60.h,
        padding: EdgeInsets.fromLTRB(12.w, 21.h, 12.w, 21.h),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(16.r),
          boxShadow: [
            BoxShadow(
              color: const Color.fromRGBO(0, 0, 0, 0.25),
              offset: Offset(0, 1.h),
              blurRadius: 7.5.r,
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Text
            Expanded(
              child: Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: 16.sp,
                  fontWeight: FontWeight.w600,
                  height: 20 / 24, // line-height control
                  letterSpacing: 0,
                  color: const Color(0xFF3B82F6),
                ),
              ),
            ),

            SizedBox(width: 10.w),

            // Icon (no background)
            Container(
              width: 28.w,
              height: 28.w,
              alignment: Alignment.center,
              child: Icon(icon, size: 18.sp, color: const Color(0xFF3B82F6)),
            ),
          ],
        ),
      ),
    );
  }
}
