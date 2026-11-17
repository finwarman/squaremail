#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift
iconutil -c icns .build/AppIcon.iconset -o macos/Resources/AppIcon.icns
