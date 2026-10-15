# Sticker Meme Maker

Flutter PWA meme editor starter.

## Run
Install Flutter SDK, then run:
```bash
flutter create --platforms=web .
flutter pub get
flutter run -d chrome
```

## Current prototype
- Import PNG/JPG/GIF/WebP image files
- Drag and resize stickers
- Add meme caption
- Render a PNG in memory (download not yet implemented)

## Next milestones
- Clipboard paste, browser sharing, and downloadable exports
- Animated GIF/WebP playback validation and MP4/GIF export
- Sticker rotation, persistent local projects and offline PWA caching

WhatsApp/TikTok sticker clipboard access is subject to browser and source app limitations.
