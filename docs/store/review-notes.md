# App Review Notes

Hao Player is a local-only Mac video player. There is no account, no network, and no in-app purchase.

How to test
1. Launch Hao Player. You should see “打开文件或拖进来”.
2. Drop or Open a local mp4 or mkv.
3. Play / pause with the bottom button or Space. Drag the slider to seek.
4. Anime4K toggle is on by default. Turn it off to see source-resolution output.
5. 流畅档 (smoothness) offers 关 / 快. Default is 关. “快” uses system frame rate conversion. Performance warnings preserve the selection; processing failures pause playback until the user retries or disables the failed feature.
6. Close the window, then reopen from 窗口 → 播放器 or ⌘0.

Why FFmpeg is in the bundle
- Dynamic LGPL FFmpeg 7.1.1 for mkv / webm / avi / ts / flv. No --enable-gpl / --enable-nonfree / --enable-version3.
- VideoToolbox decodes; no libmpv, no JIT, no Homebrew paths.
- Entitlements are only app-sandbox, user-selected read-only files, and app-scoped bookmarks.

Privacy
- No tracking, no analytics, no network entitlement.
- UserDefaults stores a security-scoped bookmark and resume time only.

Support / LGPL written offer: support@hao.app
