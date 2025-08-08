import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'screens/home_screen.dart';
import 'screens/no_internet_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/constant.dart';
import 'dart:async';
import 'dart:io';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _isConnected = true;
  bool _loading = true;
  Timer? _internetCheckTimer;

  @override
  void initState() {
    super.initState();
    _checkInitialConnectivity();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      _updateConnectionStatus(results);
    });

    // Check internet connectivity every 10 seconds
    _internetCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (timer) => _checkActualInternetConnectivity(),
    );
  }

  Future<bool> _hasInternetConnection() async {
    try {
      // First check if we have network connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        return false;
      }

      // Then test actual internet connectivity by pinging Google's DNS
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 5));

      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return true;
      }
    } catch (e) {
      // Any error means no internet
      return false;
    }
    return false;
  }

  Future<void> _checkInitialConnectivity() async {
    final hasInternet = await _hasInternetConnection();
    setState(() {
      _isConnected = hasInternet;
      _loading = false;
    });
  }

  Future<void> _checkActualInternetConnectivity() async {
    final hasInternet = await _hasInternetConnection();
    if (_isConnected != hasInternet) {
      setState(() {
        _isConnected = hasInternet;
      });
    }
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final bool hasNetworkConnection = !results.contains(
      ConnectivityResult.none,
    );
    if (!hasNetworkConnection) {
      // If no network connection at all, immediately show no internet screen
      setState(() {
        _isConnected = false;
      });
    } else {
      // If network connection is available, check actual internet connectivity
      _checkActualInternetConnectivity();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    _internetCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UniTrack',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _isConnected
          ? HomeScreen()
          : const NoInternetScreen(),
    );
  }
}
