#!/bin/sh
# Builds VectorContourSetup.exe on macOS/Linux with Mono (brew install mono / apt install mono-devel).
cd "$(dirname "$0")/.." && mkdir -p dist && \
mcs -target:winexe -platform:anycpu -sdk:4.5 -r:System.Windows.Forms.dll \
    -resource:winsetup.ps1,winsetup.ps1 -out:dist/VectorContourSetup.exe launcher/Launcher.cs
