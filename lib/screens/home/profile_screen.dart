import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

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
                    child: const InfoBannerCard(
                      name: 'Mayank Tripathi',
                      email: 'mayanktripathi7861@gmail.com',
                    ),
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
                      onTap: () {},
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
