import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AuthButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;

  const AuthButton({super.key, required this.text, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 312,
        height: 52,
        decoration: BoxDecoration(
          color: const Color.fromRGBO(35, 69, 155, 1),
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color.fromRGBO(0, 0, 0, 0.25),
              offset: Offset(0, 4),
              blurRadius: 17.6,
              spreadRadius: -2,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w400,
            fontSize: 20,
            height: 1.0,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
