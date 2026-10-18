#!/usr/bin/env bash
set -euo pipefail
FLUTTER_VERSION="${FLUTTER_VERSION:-3.35.7}"
git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /tmp/flutter
export PATH="/tmp/flutter/bin:$PATH"
flutter config --enable-web
flutter create --platforms=web --project-name=sticker_meme_maker .
flutter pub get
flutter build web --release --pwa-strategy=offline-first

cp web_export/animated_export.js build/web/animated_export.js
python3 - <<'PY'
from pathlib import Path
p = Path('build/web/index.html')
s = p.read_text()
s = s.replace('</head>', '<script src="animated_export.js" defer></script>\n</head>')
p.write_text(s)
PY
