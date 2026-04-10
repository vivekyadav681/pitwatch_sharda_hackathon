import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class MainNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int>? onTap;

  const MainNavBar({Key? key, this.selectedIndex = 0, this.onTap})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 312.w,
      height: 91.h,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            offset: const Offset(0, 1),
            blurRadius: 4,
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.w),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(_items.length, (i) {
            final item = _items[i];
            final selected = i == selectedIndex;

            return GestureDetector(
              onTap: () => onTap?.call(i),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 48.w,
                    height: 48.w,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFE9ECF4)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12.r),
                    ),
                    child: Icon(
                      item.icon,
                      color: selected
                          ? const Color(0xFF1E3A8A)
                          : const Color(0xFF64748B),
                      size: 20.sp,
                    ),
                  ),
                  SizedBox(height: 8.h),
                  Text(
                    item.label,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.sp,
                      height: 16 / 12,
                      color: selected
                          ? const Color(0xFF1E3A8A)
                          : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

const List<_NavItem> _items = [
  _NavItem(Icons.home_outlined, 'Home'),
  _NavItem(Icons.history, 'History'),
  _NavItem(Icons.person, 'Profile'),
];
