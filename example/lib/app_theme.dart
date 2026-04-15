import 'package:flutter/material.dart';

const Color brandGreen = Color(0xFF2F6B3F);
const Color brandGreenLight = Color(0xFFE4F0E7);
const Color brandGreenBorder = Color(0xFF9EBDA6);
const Color surfaceNeutral = Color(0xFFF8FAF8);
const Color surfaceNeutralBorder = Color(0xFFD7E1D7);

ThemeData buildExampleTheme() {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: brandGreen,
      surface: surfaceNeutral,
    ),
    scaffoldBackgroundColor: surfaceNeutral,
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: brandGreen,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: brandGreen,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
  );
}
