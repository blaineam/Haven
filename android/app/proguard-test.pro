# R8 config for the androidTest APK of the `minified` build type (never the app itself).
#
# AGP runs the test APK through R8 too, with the app's mapping applied so test code calls the
# obfuscated names. The test APK itself must stay as written: JUnit and AndroidJUnitRunner find
# test classes and methods by reflection, and `am instrument -e class …` names them.
-dontshrink
-dontoptimize
-dontobfuscate
# Compile-time-only annotation types the test libraries reference (errorprone / javax.lang.model).
-dontwarn javax.lang.model.**
-dontwarn com.google.errorprone.annotations.**
