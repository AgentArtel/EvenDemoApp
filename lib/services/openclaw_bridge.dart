import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// OpenClaw WebSocket Bridge Service
/// 
/// Maintains a WebSocket connection to the OpenClaw gateway and handles
/// sending user queries and receiving agent responses.
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
  
  // Response futures keyed by request ID
  final Map<String, Completer<String?>> _pendingRequests = {};
  
  // Connection status stream controller
  final _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;
  
  // WebSocket URL - default to localhost, configurable via environment
  String get _wsUrl {
    // TODO: Read from environment variable OPENCLAW_WS_URL in future
    const defaultUrl = 'ws://localhost:18789';
    return defaultUrl;
  }

  /// Connect to OpenClaw gateway
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

      // Send connect handshake
      await _sendConnectRequest();
      
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

  /// Send connect handshake request
  Future<void> _sendConnectRequest() async {
    final connectRequest = {
      'type': 'req',
      'id': 'connect-${DateTime.now().millisecondsSinceEpoch}',
      'method': 'connect',
      'params': {
        'minProtocol': 3,
        'maxProtocol': 3,
        'client': {
          'id': 'eveng1-flutter',
          'version': '1.0.0',
          'platform': 'android',
          'mode': 'node',
        },
        'role': 'node',
        'scopes': ['node.read', 'node.write'],
        'caps': [],
        'commands': [],
        'permissions': {},
        'auth': {}, // Minimal auth for local development
        'locale': 'en-US',
        'userAgent': 'eveng1-flutter/1.0.0',
      },
    };

    _channel?.sink.add(jsonEncode(connectRequest));
    print('[OpenClawBridge] Sent connect request');
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic message) {
    try {
      final data = jsonDecode(message.toString());
      final type = data['type'] as String?;
      final id = data['id'] as String?;

      if (type == 'res' && id != null) {
        // Response to a request
        final completer = _pendingRequests.remove(id);
        if (completer != null) {
          if (data['ok'] == true) {
            final payload = data['payload'];
            // Extract text from payload - format may vary, try common fields
            String? text;
            if (payload is Map) {
              text = payload['text'] as String? ?? 
                     payload['content'] as String? ??
                     payload['message'] as String?;
            }
            completer.complete(text);
          } else {
            final error = data['error'] ?? 'Unknown error';
            print('[OpenClawBridge] Request $id failed: $error');
            completer.complete(null);
          }
        }
      } else if (type == 'event') {
        // Handle events (presence, tick, etc.) - minimal implementation for now
        final event = data['event'] as String?;
        print('[OpenClawBridge] Received event: $event');
      } else if (type == 'res' && id == null) {
        // Connect response
        if (data['ok'] == true) {
          print('[OpenClawBridge] Connect handshake successful');
        } else {
          print('[OpenClawBridge] Connect handshake failed: ${data['error']}');
          _handleDisconnect();
        }
      }
    } catch (e) {
      print('[OpenClawBridge] Error parsing message: $e');
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
    
    // Complete all pending requests with null
    for (final completer in _pendingRequests.values) {
      completer.complete(null);
    }
    _pendingRequests.clear();
    
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

  /// Send a message to OpenClaw and wait for response
  /// 
  /// Returns the agent response text, or null if connection failed or timeout
  Future<String?> sendMessage(String text) async {
    if (!_isConnected) {
      // Try to connect if not connected
      final connected = await connect();
      if (!connected) {
        print('[OpenClawBridge] Cannot send message: not connected');
        return null;
      }
    }

    final requestId = 'msg-${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<String?>();

    // Set timeout (30 seconds)
    Timer(Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        _pendingRequests.remove(requestId);
        print('[OpenClawBridge] Request $requestId timed out');
      }
    });

    _pendingRequests[requestId] = completer;

    try {
      final request = {
        'type': 'req',
        'id': requestId,
        'method': 'send',
        'params': {
          'channel': 'eveng1',
          'accountId': 'default',
          'text': text,
        },
      };

      _channel?.sink.add(jsonEncode(request));
      print('[OpenClawBridge] Sent message: ${text.substring(0, text.length > 50 ? 50 : text.length)}...');
      
      return await completer.future;
    } catch (e) {
      _pendingRequests.remove(requestId);
      print('[OpenClawBridge] Error sending request: $e');
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
    
    // Complete all pending requests
    for (final completer in _pendingRequests.values) {
      completer.complete(null);
    }
    _pendingRequests.clear();
    
    print('[OpenClawBridge] Disconnected');
  }

  /// Check if currently connected
  bool get isConnected => _isConnected;
}

