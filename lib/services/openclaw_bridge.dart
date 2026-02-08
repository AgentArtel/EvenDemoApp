import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Response from OpenClaw channel with paginated pages
class OpenClawResponse {
  final String text;
  final List<String> pages;
  final String? messageId;
  
  OpenClawResponse({
    required this.text,
    required this.pages,
    this.messageId,
  });
}

/// OpenClaw WebSocket Bridge Service
/// 
/// Maintains a WebSocket connection to the eveng1 channel WebSocket server and handles
/// sending user queries and receiving paginated agent responses.
class OpenClawBridgeService {
  static OpenClawBridgeService? _instance;
  static OpenClawBridgeService get() {
    _instance ??= OpenClawBridgeService._();
    return _instance!;
  }

  OpenClawBridgeService._();

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  
  // Single completer for the current message (channel handles one at a time)
  Completer<OpenClawResponse?>? _currentRequest;
  
  // Connection status stream controller
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  
  // WebSocket URL - connects to eveng1 channel WebSocket server (port 3377)
  String get _wsUrl {
    // TODO: Read from environment variable OPENCLAW_WS_URL in future
    const defaultUrl = 'ws://localhost:3377';
    return defaultUrl;
  }

  /// Connect to eveng1 channel WebSocket server
  Future<bool> connect() async {
    if (_isConnected || _isConnecting) {
      return _isConnected;
    }

    _isConnecting = true;
    print('[OpenClawBridge] Connecting to $_wsUrl...');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      
      // Listen for messages
      _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnect,
        cancelOnError: false,
      );
      
      _isConnected = true;
      _isConnecting = false;
      _reconnectAttempts = 0;
      _connectionStatusController.add(true);
      print('[OpenClawBridge] Connected successfully');
      return true;
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      _connectionStatusController.add(false);
      print('[OpenClawBridge] Connection failed: $e');
      return false;
    }
  }

  /// Handle incoming WebSocket messages (TASK-007 protocol)
  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'] as String?;

      if (type == 'response') {
        // Agent response with paginated pages
        final text = data['text'] as String? ?? '';
        final pagesData = data['pages'];
        final messageId = data['messageId'] as String?;
        
        List<String> pages = [];
        if (pagesData is List) {
          pages = pagesData.map((p) => p.toString()).toList();
        } else if (text.isNotEmpty) {
          // Fallback: create single page from text if pages not provided
          pages = [text];
        }
        
        final response = OpenClawResponse(
          text: text,
          pages: pages,
          messageId: messageId, // Store for potential future use (logging, tracking)
        );
        
        if (_currentRequest != null && !_currentRequest!.isCompleted) {
          _currentRequest!.complete(response);
          _currentRequest = null;
        }
        
        print('[OpenClawBridge] Received response (${pages.length} pages)');
      } else if (type == 'error') {
        // Error response
        final error = data['error'] as String? ?? 'Unknown error';
        final messageId = data['messageId'] as String?;
        
        print('[OpenClawBridge] Received error: $error');
        
        // Complete with null to indicate error
        if (_currentRequest != null && !_currentRequest!.isCompleted) {
          _currentRequest!.complete(null);
          _currentRequest = null;
        }
      } else {
        print('[OpenClawBridge] Unknown message type: $type');
      }
    } catch (e) {
      print('[OpenClawBridge] Error parsing message: $e');
      // Complete request with null on parse error
      if (_currentRequest != null && !_currentRequest!.isCompleted) {
        _currentRequest!.complete(null);
        _currentRequest = null;
      }
    }
  }

  /// Handle WebSocket errors
  void _handleError(dynamic error) {
    print('[OpenClawBridge] WebSocket error: $error');
    _handleDisconnect();
  }

  /// Handle WebSocket disconnect
  void _handleDisconnect() {
    if (!_isConnected) return;
    
    _isConnected = false;
    _connectionStatusController.add(false);
    print('[OpenClawBridge] Disconnected');
    
    // Complete current request with null
    if (_currentRequest != null && !_currentRequest!.isCompleted) {
      _currentRequest!.complete(null);
      _currentRequest = null;
    }
    
    // Attempt reconnection with exponential backoff
    if (_reconnectAttempts < _maxReconnectAttempts) {
      _attemptReconnect();
    }
  }

  /// Attempt to reconnect with exponential backoff
  void _attemptReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print('[OpenClawBridge] Max reconnection attempts reached. Manual reconnect required.');
      return;
    }

    _reconnectAttempts++;
    final delaySeconds = 1 << (_reconnectAttempts - 1); // 1s, 2s, 4s
    print('[OpenClawBridge] Reconnecting in $delaySeconds seconds (attempt $_reconnectAttempts/$_maxReconnectAttempts)...');
    
    Future.delayed(Duration(seconds: delaySeconds), () {
      if (!_isConnected) {
        connect();
      }
    });
  }

  /// Send a message to OpenClaw channel and wait for paginated response
  /// 
  /// Returns the agent response with paginated pages, or null if connection failed or timeout
  Future<OpenClawResponse?> sendMessage(String text) async {
    if (!_isConnected) {
      // Try to connect if not connected
      final connected = await connect();
      if (!connected) {
        print('[OpenClawBridge] Cannot send message: not connected');
        return null;
      }
    }

    // Cancel any existing request
    if (_currentRequest != null && !_currentRequest!.isCompleted) {
      _currentRequest!.complete(null);
    }

    final completer = Completer<OpenClawResponse?>();
    _currentRequest = completer;

    // Set timeout (30 seconds)
    Timer(Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        _currentRequest = null;
        print('[OpenClawBridge] Request timed out');
      }
    });

    try {
      // Send message using TASK-007 protocol
      final message = {
        'type': 'message',
        'text': text,
      };

      _channel?.sink.add(jsonEncode(message));
      print('[OpenClawBridge] Sent message: ${text.substring(0, text.length > 50 ? 50 : text.length)}...');
      
      return await completer.future;
    } catch (e) {
      _currentRequest = null;
      print('[OpenClawBridge] Error sending message: $e');
      return null;
    }
  }

  /// Disconnect from OpenClaw gateway
  void disconnect() {
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
    _reconnectAttempts = 0;
    _connectionStatusController.add(false);
    
    // Complete current request
    if (_currentRequest != null && !_currentRequest!.isCompleted) {
      _currentRequest!.complete(null);
      _currentRequest = null;
    }
    
    print('[OpenClawBridge] Disconnected');
  }

  /// Check if currently connected
  bool get isConnected => _isConnected;
}

