#!/bin/bash
# Builds the key injector (injector/Inj.java) into injector/inj.dex, ready to push to a Fire TV. Needs the Android SDK (android.jar, d8) and a JDK 17.
set -euo pipefail
cd "$(dirname "$0")/injector"
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}; export PATH="$JAVA_HOME/bin:$PATH"
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
JAR=$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)
D8=$(ls "$SDK"/build-tools/*/d8 | sort -V | tail -1)
JAVAC=$JAVA_HOME/bin/javac
rm -rf out && mkdir out
"$JAVAC" -source 8 -target 8 -cp "$JAR" -d out Inj.java 2>&1 | grep -v "warning" || true
"$D8" --min-api 24 --lib "$JAR" --output out out/Inj.class
mv out/classes.dex inj.dex && rm -rf out
echo "built $(pwd)/inj.dex"
