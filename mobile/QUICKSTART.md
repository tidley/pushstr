# Pushstr Mobile - Quick Start

## 🚀 Run the App (3 Steps)

### 1. Install Dependencies
```bash
cd /home/tom/code/pushstr/mobile
flutter pub get
```

### 2. Connect Android Device
- Enable USB debugging on your Android phone
- Connect via USB
- Verify: `flutter devices`

### 3. Run
```bash
flutter run
```

That's it! The app will compile and install on your device.

## 📦 Build APK

```bash
flutter build apk --release
```

APK location: `build/app/outputs/flutter-apk/app-release.apk`

## 🔑 Usage

1. **First Launch**: App auto-generates an nsec key
2. **Import Key**: Menu → Settings → Import nsec (to use extension key)
3. **Add Contact**: Menu → Add Contact → Enter nickname & npub
4. **Send Message**: Select contact → Type → Send
5. **Refresh**: Tap refresh icon to fetch new messages

## 🔧 Quick Commands

```bash
# Check Flutter setup
flutter doctor

# List connected devices
flutter devices

# Run in debug mode
flutter run

# Run in release mode
flutter run --release

# Build APK
flutter build apk --release

# Build app bundle (for Play Store)
flutter build appbundle --release

# Clean build
flutter clean && flutter pub get

# Analyze code
flutter analyze

# Run tests
flutter test
```

## 📱 Default Relays

- wss://relay.damus.io
- wss://relay.snort.social
- wss://offchain.pub

## 🐛 Troubleshooting

**No devices found:**
```bash
# Check USB connection
adb devices

# Restart adb server
adb kill-server
adb start-server
```

**Build fails:**
```bash
# Clean and rebuild
flutter clean
flutter pub get
flutter run
```

**Gradle errors:**
```bash
cd android
./gradlew clean
cd ..
flutter run
```

## 📚 Full Documentation

See `MOBILE_APP_GUIDE.md` in the root directory for complete documentation.

## ✅ Status

- ✅ Rust FFI integrated
- ✅ Android native libraries built
- ✅ NIP-04 encryption working
- ✅ Send/receive DMs working
- ✅ Contact management working
- ✅ Message history working
- ✅ Share intent working
- ⏳ Ready for testing on device

## 🎯 Next Steps

1. Test on real Android device
2. Verify message send/receive
3. Test with browser extension (same nsec)
4. Add push notifications
5. Publish to Play Store (optional)
