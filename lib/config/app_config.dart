/// App configuration for ClawLens Flutter app
/// 
/// Update these URLs based on your deployment:
/// - Development: Use localhost
/// - Production: Use Railway or your cloud deployment URL
class AppConfig {
  // Production WebSocket URL (Railway or your cloud deployment)
  // Update this with your actual Railway domain
  static const String openClawWsUrlProduction = 'wss://your-railway-app.up.railway.app:3377';
  
  // Local development WebSocket URL
  static const String openClawWsUrlDevelopment = 'ws://localhost:3377';
  
  // For device testing on same network (use your computer's IP)
  // Example: 'ws://192.168.1.100:3377'
  static const String openClawWsUrlLocalNetwork = 'ws://192.168.1.100:3377';
  
  /// Get the WebSocket URL based on build mode
  /// 
  /// In release builds, uses production URL.
  /// In debug builds, uses development URL.
  /// 
  /// To override, set OPENCLAW_WS_URL environment variable:
  /// flutter run --dart-define=OPENCLAW_WS_URL=ws://your-url:3377
  static String get openClawWsUrl {
    // Check for environment variable override
    const envUrl = String.fromEnvironment('OPENCLAW_WS_URL');
    if (envUrl.isNotEmpty) {
      return envUrl;
    }
    
    // Use production URL in release builds
    const bool isRelease = bool.fromEnvironment('dart.vm.product');
    if (isRelease) {
      return openClawWsUrlProduction;
    }
    
    // Use development URL in debug builds
    return openClawWsUrlDevelopment;
  }
  
  /// Get the WebSocket URL for local network testing
  /// Use this when testing on a physical device on the same network
  static String get openClawWsUrlForDevice {
    return openClawWsUrlLocalNetwork;
  }
}

