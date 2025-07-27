import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Chat App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: BLEChatScreen(),
    );
  }
}

class BLEChatScreen extends StatefulWidget {
  @override
  _BLEChatScreenState createState() => _BLEChatScreenState();
}

class _BLEChatScreenState extends State<BLEChatScreen> {
  static const String SERVICE_UUID = "12345678-1234-1234-1234-123456789abc";
  static const String CHARACTERISTIC_UUID =
      "87654321-4321-4321-4321-cba987654321";
  static const String DEVICE_NAME = "BO_Chat";
  static const MethodChannel _channel = MethodChannel('ble_peripheral');

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _chatCharacteristic;
  final List<ChatMessage> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isPeripheralMode = false;
  bool _isAdvertising = false;
  List<ScanResult> _scanResults = [];
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Add this to track the last sent message to avoid duplicates
  String? _lastSentMessage;
  DateTime? _lastSentTime;

  // Add connection status tracking
  bool _isConnecting = false;
  String? _connectionError;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupPeripheralChannel();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _characteristicSubscription?.cancel();
    _scanSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _stopAdvertising();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.nearbyWifiDevices,
      ].request();
    }
  }

  void _setupPeripheralChannel() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onMessageReceived':
          _addMessage(call.arguments['message'], false);
          break;
        case 'onDeviceConnected':
          setState(() => _isConnected = true);
          _showSnackBar('Device connected!');
          break;
        case 'onDeviceDisconnected':
          setState(() => _isConnected = false);
          _showSnackBar('Device disconnected!');
          break;
        case 'onAdvertisingStarted':
          setState(() => _isAdvertising = true);
          break;
        case 'onAdvertisingFailed':
          setState(() {
            _isAdvertising = false;
            _isPeripheralMode = false;
          });
          _showSnackBar(
            'Advertising failed: ${call.arguments?['error'] ?? 'Unknown error'}',
          );
          break;
      }
    });
  }

  Future<void> _startPeripheralMode() async {
    try {
      setState(() {
        _isPeripheralMode = true;
        _isAdvertising = false; // Will be set to true in callback
      });

      await _channel.invokeMethod('startPeripheral', {
        'serviceUUID': SERVICE_UUID,
        'characteristicUUID': CHARACTERISTIC_UUID,
        'deviceName': DEVICE_NAME,
      });

      _showSnackBar('Started as Peripheral - Waiting for connections...');
    } catch (e) {
      _showSnackBar('Peripheral mode failed: $e');
      setState(() {
        _isAdvertising = false;
        _isPeripheralMode = false;
      });
    }
  }

  Future<void> _stopAdvertising() async {
    try {
      await _channel.invokeMethod('stopPeripheral');
      setState(() {
        _isAdvertising = false;
        _isPeripheralMode = false;
        _isConnected = false;
      });
    } catch (e) {
      debugPrint('Error stopping peripheral: $e');
    }
  }

  Future<void> _sendMessageAsPeripheral(String message) async {
    try {
      await _channel.invokeMethod('sendMessage', {'message': message});
      _addMessage(message, true);
      _messageController.clear();
    } catch (e) {
      _showSnackBar('Failed to send message: $e');
    }
  }

  Future<void> _startCentralMode() async {
    setState(() => _isPeripheralMode = false);
    await _startScanning();
  }

  Future<void> _startScanning() async {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _scanResults.clear();
      _connectionError = null;
    });

    try {
      // Cancel any existing scan subscription
      await _scanSubscription?.cancel();

      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: 15),
        withServices: [Guid(SERVICE_UUID)],
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            _scanResults = results
                .where(
                  (r) =>
                      r.device.advName.isNotEmpty ||
                      r.advertisementData.advName.isNotEmpty,
                )
                .toList();
          });
        }
      });

      await Future.delayed(Duration(seconds: 15));
      await FlutterBluePlus.stopScan();
    } catch (e) {
      _showSnackBar('Scanning failed: $e');
      setState(() => _connectionError = 'Scanning failed: $e');
    }

    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      // Cancel any existing connections
      await _connectionSubscription?.cancel();
      await _characteristicSubscription?.cancel();

      await device.connect(timeout: Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _connectedDevice = device;
          _isConnected = true;
          _isConnecting = false;
        });
      }

      _connectionSubscription = device.connectionState.listen((state) {
        if (mounted) {
          if (state == BluetoothConnectionState.disconnected) {
            setState(() {
              _isConnected = false;
              _connectedDevice = null;
              _chatCharacteristic = null;
              _isConnecting = false;
            });
            _showSnackBar('Disconnected from device');
          }
        }
      });

      await _discoverServices();
      _showSnackBar(
        'Connected to ${device.advName.isEmpty ? "Device" : device.advName}',
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _connectionError = 'Connection failed: $e';
        });
      }
      _showSnackBar('Connection failed: $e');
    }
  }

  Future<void> _discoverServices() async {
    if (_connectedDevice == null) return;

    try {
      List<BluetoothService> services = await _connectedDevice!
          .discoverServices();

      for (BluetoothService service in services) {
        if (service.uuid.toString().toLowerCase() ==
            SERVICE_UUID.toLowerCase()) {
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() ==
                CHARACTERISTIC_UUID.toLowerCase()) {
              _chatCharacteristic = characteristic;

              if (characteristic.properties.notify) {
                await characteristic.setNotifyValue(true);

                // Cancel any existing subscription
                await _characteristicSubscription?.cancel();

                _characteristicSubscription = characteristic.lastValueStream
                    .listen((value) {
                      if (value.isNotEmpty && mounted) {
                        try {
                          String message = utf8.decode(value);

                          // Check if this is our own message echoed back
                          if (_lastSentMessage != null &&
                              _lastSentTime != null &&
                              message == _lastSentMessage &&
                              DateTime.now()
                                      .difference(_lastSentTime!)
                                      .inSeconds <
                                  1) {
                            return; // Ignore echo
                          }

                          _addMessage(message, false);
                        } catch (e) {
                          debugPrint('Error decoding message: $e');
                        }
                      }
                    });
              }
              break;
            }
          }
          break;
        }
      }
    } catch (e) {
      _showSnackBar('Service discovery failed: $e');
    }
  }

  Future<void> _sendMessageAsCentral(String message) async {
    if (_chatCharacteristic == null || message.trim().isEmpty) return;

    try {
      List<int> bytes = utf8.encode(message);

      // Store the message and timestamp to detect echoes
      _lastSentMessage = message;
      _lastSentTime = DateTime.now();

      if (_chatCharacteristic!.properties.write) {
        await _chatCharacteristic!.write(bytes, withoutResponse: false);
      } else if (_chatCharacteristic!.properties.writeWithoutResponse) {
        await _chatCharacteristic!.write(bytes, withoutResponse: true);
      }

      _addMessage(message, true);
      _messageController.clear();
    } catch (e) {
      _showSnackBar('Failed to send message: $e');
    }
  }

  void _sendMessage(String message) {
    if (message.trim().isEmpty) return;

    if (_isPeripheralMode) {
      _sendMessageAsPeripheral(message);
    } else {
      _sendMessageAsCentral(message);
    }
  }

  void _addMessage(String message, bool isSent) {
    if (mounted) {
      setState(() {
        _messages.add(
          ChatMessage(text: message, isSent: isSent, timestamp: DateTime.now()),
        );
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: Duration(seconds: 3)),
      );
    }
  }

  Future<void> _disconnect() async {
    if (_isPeripheralMode) {
      await _stopAdvertising();
    } else if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
    }

    if (mounted) {
      setState(() {
        _messages.clear();
        _lastSentMessage = null;
        _lastSentTime = null;
        _connectionError = null;
        _isConnecting = false;
      });
    }
  }

  Future<void> _refreshScan() async {
    await FlutterBluePlus.stopScan();
    await _startScanning();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('BLE Chat ${_isPeripheralMode ? "(Server)" : "(Client)"}'),
        backgroundColor: _isPeripheralMode ? Colors.green : Colors.blue,
        actions: [
          if (_isConnected || _isAdvertising)
            IconButton(icon: Icon(Icons.power_off), onPressed: _disconnect),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          Expanded(
            child: (_isConnected || (_isPeripheralMode && _isAdvertising))
                ? _buildChatUI()
                : _buildSetupUI(),
          ),
          if (_isConnected) _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    Color statusColor;
    String statusText;

    if (_isPeripheralMode && _isAdvertising) {
      statusColor = _isConnected ? Colors.green : Colors.orange;
      statusText = _isConnected
          ? 'Server: Device Connected'
          : 'Server: Waiting for connection...';
    } else if (_isConnected) {
      statusColor = Colors.green;
      statusText =
          'Client: Connected to ${_connectedDevice?.advName ?? "Device"}';
    } else if (_isConnecting) {
      statusColor = Colors.orange;
      statusText = 'Connecting...';
    } else {
      statusColor = Colors.red;
      statusText = 'Not Connected';
    }

    return Container(
      padding: EdgeInsets.all(12),
      color: statusColor.withOpacity(0.2),
      child: Row(
        children: [
          Icon(
            _isPeripheralMode ? Icons.router : Icons.phone_android,
            color: statusColor,
            size: 20,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.bold),
            ),
          ),
          if (_isConnecting)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSetupUI() {
    return Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth, size: 80, color: Colors.blue.withOpacity(0.7)),
          SizedBox(height: 24),
          Text(
            'BLE Chat Setup',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          SizedBox(height: 16),
          Text(
            'Choose your device role:',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: (_isAdvertising || _isScanning)
                ? null
                : _startPeripheralMode,
            icon: Icon(Icons.router),
            label: Text(
              _isAdvertising ? 'Starting Server...' : 'Start as Server',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              minimumSize: Size(double.infinity, 50),
            ),
          ),
          SizedBox(height: 16),
          Text('OR', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: (_isScanning || _isAdvertising)
                ? null
                : _startCentralMode,
            icon: Icon(_isScanning ? Icons.hourglass_empty : Icons.search),
            label: Text(_isScanning ? 'Scanning...' : 'Join as Client'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              minimumSize: Size(double.infinity, 50),
            ),
          ),
          if (_connectionError != null) ...[
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connectionError!,
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_scanResults.isNotEmpty) ...[
            SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Available Servers:',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                IconButton(
                  onPressed: _isScanning ? null : _refreshScan,
                  icon: Icon(Icons.refresh),
                  tooltip: 'Refresh scan',
                ),
              ],
            ),
            SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _scanResults.length,
                itemBuilder: (context, index) {
                  final result = _scanResults[index];
                  final deviceName = result.device.advName.isEmpty
                      ? (result.advertisementData.advName.isEmpty
                            ? 'Unknown Device'
                            : result.advertisementData.advName)
                      : result.device.advName;

                  return Card(
                    child: ListTile(
                      leading: Icon(Icons.router, color: Colors.green),
                      title: Text(deviceName),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Signal: ${result.rssi} dBm'),
                          Text(
                            'Address: ${result.device.remoteId}',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                      trailing: _isConnecting
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(Icons.arrow_forward_ios),
                      onTap: _isConnecting
                          ? null
                          : () => _connectToDevice(result.device),
                    ),
                  );
                },
              ),
            ),
          ] else if (!_isScanning && !_isPeripheralMode) ...[
            SizedBox(height: 32),
            Text('No servers found', style: TextStyle(color: Colors.grey[600])),
            SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _refreshScan,
              icon: Icon(Icons.refresh),
              label: Text('Scan Again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[600],
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChatUI() {
    return Column(
      children: [
        if (_messages.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 60,
                    color: Colors.grey[400],
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Start chatting!',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                return _buildMessageBubble(_messages[index]);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Align(
      alignment: message.isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 6),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: message.isSent
              ? (_isPeripheralMode ? Colors.green : Colors.blue)
              : Colors.grey[300],
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: message.isSent ? Colors.white : Colors.black87,
                fontSize: 16,
              ),
            ),
            SizedBox(height: 4),
            Text(
              '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 12,
                color: message.isSent ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            spreadRadius: 1,
            blurRadius: 3,
            offset: Offset(0, -1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: 'Type a message...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              onSubmitted: _sendMessage,
              textInputAction: TextInputAction.send,
            ),
          ),
          SizedBox(width: 12),
          FloatingActionButton(
            mini: true,
            onPressed: () => _sendMessage(_messageController.text),
            backgroundColor: _isPeripheralMode ? Colors.green : Colors.blue,
            child: Icon(Icons.send, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isSent;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isSent,
    required this.timestamp,
  });
}
