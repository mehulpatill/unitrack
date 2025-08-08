import 'package:flutter/material.dart';
import 'package:flutter_osm_plugin/flutter_osm_plugin.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'dart:math' as math;
import '../config/constant.dart';

class BuggyLocation {
  final String buggyId;
  final double latitude;
  final double longitude;
  final DateTime updatedAt;
  final String? buggyNumber;
  final String? driverName;
  final String? driverPhone;
  final String? status;

  BuggyLocation({
    required this.buggyId,
    required this.latitude,
    required this.longitude,
    required this.updatedAt,
    this.buggyNumber,
    this.driverName,
    this.driverPhone,
    this.status,
  });

  GeoPoint get geoPoint => GeoPoint(latitude: latitude, longitude: longitude);

  bool get isActive => status == 'active';

  bool get isRecent => DateTime.now().difference(updatedAt).inMinutes <= 5;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BuggyLocation &&
          runtimeType == other.runtimeType &&
          buggyId == other.buggyId &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          status == other.status &&
          buggyNumber == other.buggyNumber;

  @override
  int get hashCode =>
      buggyId.hashCode ^
      latitude.hashCode ^
      longitude.hashCode ^
      status.hashCode ^
      buggyNumber.hashCode;
}

class UniversityMapWidget extends StatefulWidget {
  final bool isActive;
  const UniversityMapWidget({super.key, required this.isActive});

  @override
  State<UniversityMapWidget> createState() => _UniversityMapWidgetState();
}

class _UniversityMapWidgetState extends State<UniversityMapWidget> {
  late MapController controller;
  StreamSubscription<List<Map<String, dynamic>>>? _realtimeSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _buggiesRealtimeSubscription;
  Map<String, BuggyLocation> _buggyLocations = {};
  Map<String, GeoPoint> _markerPositions = {};
  bool _isMapReady = false;
  String _statusMessage = 'Initializing...';
  bool _isConnected = false;
  bool _isLoading = true;

  bool enableBoundaries = true;



  @override
  void initState() {
    super.initState();
    controller = MapController(
      initPosition: GeoPoint(latitude: 22.29006, longitude: 73.36328),
    );
    _initializeRealtimeConnection();
  }

  @override
  void didUpdateWidget(covariant UniversityMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _initializeRealtimeConnection();
    } else if (!widget.isActive && oldWidget.isActive) {
      _cancelSubscriptions();
      _clearAllMarkers();
      if (mounted) {
        setState(() {
          _statusMessage = 'Inactive';
          _isConnected = false;
        });
      }
    }
  }

  void _cancelSubscriptions() {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    _buggiesRealtimeSubscription?.cancel();
    _buggiesRealtimeSubscription = null;
  }

  void _initializeRealtimeConnection() {
    if (!widget.isActive) return;

    setState(() {
      _statusMessage = 'Connecting to real-time updates...';
      _isConnected = false;
      _isLoading = true;
    });

    try {
      _loadInitialData();

      // Listen to buggy_locations table for location updates
      _realtimeSubscription = Supabase.instance.client
          .from('buggy_locations')
          .stream(primaryKey: ['buggy_id'])
          .listen(
            (List<Map<String, dynamic>> data) {
              _handleRealtimeUpdate(data);
            },
            onError: (error) {
              setState(() {
                _statusMessage = 'Connection error: $error';
                _isConnected = false;
              });
            },
          );

      // Listen to buggies table for status and assignment changes
      _buggiesRealtimeSubscription = Supabase.instance.client
          .from('buggies')
          .stream(primaryKey: ['id'])
          .listen(
            (List<Map<String, dynamic>> data) {
              _handleBuggiesRealtimeUpdate(data);
            },
            onError: (error) {
              print('Buggies real-time error: $error');
            },
          );

      setState(() {
        _isConnected = true;
        _statusMessage = 'Connected to real-time updates';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Failed to connect: $e';
        _isConnected = false;
      });
    }
  }

  Future<void> _loadInitialData() async {
    try {
      final locationsResponse = await Supabase.instance.client
          .from('buggy_locations')
          .select('buggy_id, latitude, longitude, updated_at')
          .order('updated_at', ascending: false);

      if (locationsResponse.isEmpty) {
        setState(() {
          _statusMessage = 'No buggy locations found';
          _isLoading = false;
        });
        return;
      }

      final buggyIds = locationsResponse
          .map((loc) => loc['buggy_id'].toString())
          .toSet()
          .toList();

      final buggiesResponse = await Supabase.instance.client
          .from('buggies')
          .select('id, buggy_number, status, assigned_driver')
          .inFilter('id', buggyIds);

      final driverIds = buggiesResponse
          .where((buggy) => buggy['assigned_driver'] != null)
          .map((buggy) => buggy['assigned_driver'].toString())
          .toList();

      Map<String, String> driverNames = {};
      Map<String, String> driverPhones = {};
      if (driverIds.isNotEmpty) {
        try {
          final driversResponse = await Supabase.instance.client
              .from('drivers')
              .select('id, name, phone')
              .inFilter('id', driverIds);

          for (var driver in driversResponse) {
            driverNames[driver['id'].toString()] = driver['name'];
            driverPhones[driver['id'].toString()] = driver['phone'] ?? '';
          }
        } catch (e) {
          print('Error fetching driver names: $e');
        }
      }

      final List<BuggyLocation> locations = [];
      for (var location in locationsResponse) {
        final locationBuggyId = location['buggy_id'].toString();

        Map<String, dynamic>? buggy;
        try {
          buggy = buggiesResponse.firstWhere(
            (b) => b['id'].toString() == locationBuggyId,
          );
        } catch (e) {
          continue;
        }

        if (buggy['status'] == 'active') {
          final assignedDriverId = buggy['assigned_driver']?.toString();
          final driverName = assignedDriverId != null
              ? driverNames[assignedDriverId]
              : null;
          final driverPhone = assignedDriverId != null
              ? driverPhones[assignedDriverId]
              : null;

          locations.add(
            BuggyLocation(
              buggyId: locationBuggyId,
              latitude: (location['latitude'] ?? 0.0).toDouble(),
              longitude: (location['longitude'] ?? 0.0).toDouble(),
              updatedAt: DateTime.parse(location['updated_at']),
              buggyNumber: buggy['buggy_number'],
              driverName: driverName,
              driverPhone: driverPhone,
              status: buggy['status'],
            ),
          );
        }
      }

      // Initialize with active buggies
      _updateBuggyLocations(locations);
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error loading data: $e';
        _isLoading = false;
      });
    }
  }

  void _handleRealtimeUpdate(List<Map<String, dynamic>> data) async {
    try {
      final buggyIds = data
          .map((item) => item['buggy_id'].toString())
          .toSet()
          .toList();

      if (buggyIds.isEmpty) return;

      List<Map<String, dynamic>> buggiesResponse = await Supabase
          .instance
          .client
          .from('buggies')
          .select('id, buggy_number, status, assigned_driver')
          .inFilter('id', buggyIds);

      final driverIds = buggiesResponse
          .where((buggy) => buggy['assigned_driver'] != null)
          .map((buggy) => buggy['assigned_driver'].toString())
          .toList();

      Map<String, String> driverNames = {};
      Map<String, String> driverPhones = {};
      if (driverIds.isNotEmpty) {
        try {
          final driversResponse = await Supabase.instance.client
              .from('drivers')
              .select('id, name, phone')
              .inFilter('id', driverIds);

          for (var driver in driversResponse) {
            driverNames[driver['id'].toString()] = driver['name'];
            driverPhones[driver['id'].toString()] = driver['phone'] ?? '';
          }
        } catch (e) {
          print('Error fetching driver names in realtime: $e');
        }
      }

      // Process updates efficiently
      for (var locationData in data) {
        final buggyId = locationData['buggy_id'].toString();

        // Find matching buggy info
        final buggy = buggiesResponse.firstWhere(
          (b) => b['id'].toString() == buggyId,
          orElse: () => {},
        );

        if (buggy.isEmpty || buggy['status'] != 'active') continue;

        final assignedDriverId = buggy['assigned_driver']?.toString();
        final driverName = assignedDriverId != null
            ? driverNames[assignedDriverId]
            : null;
        final driverPhone = assignedDriverId != null
            ? driverPhones[assignedDriverId]
            : null;

        final newLocation = BuggyLocation(
          buggyId: buggyId,
          latitude: (locationData['latitude'] ?? 0.0).toDouble(),
          longitude: (locationData['longitude'] ?? 0.0).toDouble(),
          updatedAt: DateTime.parse(locationData['updated_at']),
          buggyNumber: buggy['buggy_number'],
          driverName: driverName,
          driverPhone: driverPhone,
          status: buggy['status'],
        );

        _updateSingleBuggyLocation(newLocation);
      }
    } catch (e) {
      print('Error handling real-time update: $e');
    }
  }

  void _handleBuggiesRealtimeUpdate(List<Map<String, dynamic>> data) async {
    try {
      if (!widget.isActive || !_isMapReady || !mounted) return;

      for (var updatedBuggy in data) {
        final buggyId = updatedBuggy['id'].toString();
        final currentLocation = _buggyLocations[buggyId];
        final newStatus = updatedBuggy['status'];

        // Handle status changes
        if (currentLocation != null) {
          if (newStatus != 'active') {
            // Remove inactive buggy
            await _removeBuggyMarker(buggyId);
            setState(() {
              _buggyLocations.remove(buggyId);
            });
          } else {
            // Update existing buggy info
            final updatedLocation = BuggyLocation(
              buggyId: currentLocation.buggyId,
              latitude: currentLocation.latitude,
              longitude: currentLocation.longitude,
              updatedAt: currentLocation.updatedAt,
              buggyNumber:
                  updatedBuggy['buggy_number'] ?? currentLocation.buggyNumber,
              driverName: currentLocation.driverName,
              driverPhone: currentLocation.driverPhone,
              status: newStatus,
            );

            // Only update if something actually changed
            if (currentLocation != updatedLocation) {
              setState(() {
                _buggyLocations[buggyId] = updatedLocation;
              });
              await _updateBuggyMarker(updatedLocation);
            }
          }
        } else if (newStatus == 'active') {
          // Handle newly active buggies
          try {
            final locationResponse = await Supabase.instance.client
                .from('buggy_locations')
                .select('latitude, longitude, updated_at')
                .eq('buggy_id', buggyId)
                .order('updated_at', ascending: false)
                .limit(1)
                .single();

            // Get driver information if assigned
            String? driverName;
            String? driverPhone;

            if (updatedBuggy['assigned_driver'] != null) {
              try {
                final driverResponse = await Supabase.instance.client
                    .from('drivers')
                    .select('name, phone')
                    .eq('id', updatedBuggy['assigned_driver'])
                    .single();

                driverName = driverResponse['name'];
                driverPhone = driverResponse['phone'] ?? '';
              } catch (e) {
                print('Error fetching driver info for new active buggy: $e');
              }
            }

            final newBuggyLocation = BuggyLocation(
              buggyId: buggyId,
              latitude: (locationResponse['latitude'] ?? 0.0).toDouble(),
              longitude: (locationResponse['longitude'] ?? 0.0).toDouble(),
              updatedAt: DateTime.parse(locationResponse['updated_at']),
              buggyNumber: updatedBuggy['buggy_number'],
              driverName: driverName,
              driverPhone: driverPhone,
              status: newStatus,
            );

            // Add to tracked locations and create marker
            setState(() {
              _buggyLocations[buggyId] = newBuggyLocation;
            });
            await _addBuggyMarker(newBuggyLocation);
          } catch (e) {
            print('Error adding newly active buggy: $e');
          }
        }
      }

      // Update status message
      setState(() {
        _statusMessage = '${_buggyLocations.length} buggies online';
      });
    } catch (e) {
      print('Error handling buggies real-time update: $e');
    }
  }

  void _updateBuggyLocations(List<BuggyLocation> locations) async {
    if (!_isMapReady || !mounted || !widget.isActive) return;

    // Clear existing markers
    await _clearAllMarkers();

    // Add new markers
    for (var location in locations) {
      if (location.isActive) {
        setState(() {
          _buggyLocations[location.buggyId] = location;
        });
        await _addBuggyMarker(location);
      }
    }

    setState(() {
      _statusMessage = '${_buggyLocations.length} buggies online';
      _isConnected = true;
    });
  }

  void _updateSingleBuggyLocation(BuggyLocation newLocation) async {
    if (!_isMapReady || !mounted || !widget.isActive) return;

    final currentLocation = _buggyLocations[newLocation.buggyId];
    final isNewBuggy = currentLocation == null;

    // Check if position actually changed
    final positionChanged =
        isNewBuggy ||
        currentLocation.latitude != newLocation.latitude ||
        currentLocation.longitude != newLocation.longitude;

    // Check if any relevant data changed
    final dataChanged =
        isNewBuggy ||
        currentLocation.status != newLocation.status ||
        currentLocation.buggyNumber != newLocation.buggyNumber ||
        positionChanged;

    // Skip if nothing important changed
    if (!dataChanged) {
      return;
    }

    // Update location data
    setState(() {
      _buggyLocations[newLocation.buggyId] = newLocation;
    });

    // Update marker - always update if position changed or it's a new buggy
    if (isNewBuggy) {
      await _addBuggyMarker(newLocation);
    } else if (positionChanged || dataChanged) {
      await _updateBuggyMarker(newLocation);
    }

    // Update status message periodically
    if (_buggyLocations.length % 5 == 0 || isNewBuggy) {
      setState(() {
        _statusMessage = '${_buggyLocations.length} buggies online';
      });
    }
  }

  Future<void> _addBuggyMarker(BuggyLocation location) async {
    try {
      final markerIcon = await _createBuggyMarkerIcon(location);
      await controller.addMarker(location.geoPoint, markerIcon: markerIcon);
      _markerPositions[location.buggyId] = location.geoPoint;
    } catch (e) {
      print('Error adding buggy marker: $e');
    }
  }

  Future<void> _updateBuggyMarker(BuggyLocation location) async {
    try {
      // Always remove old marker first
      final oldPosition = _markerPositions[location.buggyId];
      if (oldPosition != null) {
        await controller.removeMarker(oldPosition);
        _markerPositions.remove(location.buggyId);
      }

      // Add updated marker at new position
      final markerIcon = await _createBuggyMarkerIcon(location);
      await controller.addMarker(location.geoPoint, markerIcon: markerIcon);
      _markerPositions[location.buggyId] = location.geoPoint;
    } catch (e) {
      print('Error updating buggy marker: $e');
    }
  }

  Future<void> _removeBuggyMarker(String buggyId) async {
    try {
      final position = _markerPositions[buggyId];
      if (position != null) {
        await controller.removeMarker(position);
        _markerPositions.remove(buggyId);
      }
    } catch (e) {
      print('Error removing buggy marker: $e');
    }
  }

  Future<void> _clearAllMarkers() async {
    try {
      if (_markerPositions.isNotEmpty) {
        await controller.removeMarkers(_markerPositions.values.toList());
        _markerPositions.clear();
      }
    } catch (e) {
      print('Error clearing markers: $e');
    }
  }

  Future<MarkerIcon> _createBuggyMarkerIcon(BuggyLocation location) async {
    try {
      final isRecent = location.isRecent;
      final primaryColor = isRecent ? Colors.green[500]! : Colors.orange[500]!;

      return MarkerIcon(
        iconWidget: Container(
          width: 70,
          height: 85,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enhanced buggy number badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, primaryColor.withOpacity(0.8)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.4),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Text(
                  location.buggyNumber ?? 'N/A',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(height: 4),

              // Enhanced buggy icon
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [Colors.white, Colors.grey[100]!],
                  ),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: primaryColor, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Container(
                    decoration: const BoxDecoration(
                      image: DecorationImage(
                        image: AssetImage("assets/png/golf-cart.png"),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),

              // Status indicator dot
              Container(
                margin: const EdgeInsets.only(top: 3),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.5),
                      blurRadius: 4,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      return MarkerIcon(
        icon: Icon(
          Icons.directions_car,
          color: location.isRecent ? Colors.green[500] : Colors.orange[500],
          size: 32,
        ),
      );
    }
  }

  Future<void> _setMapBoundaries() async {
    if (!enableBoundaries || !_isMapReady) return;

    try {
      await controller.limitAreaMap(
        BoundingBox(
          east: eastBoundary,
          north: northBoundary,
          south: southBoundary,
          west: westBoundary,
        ),
      );
    } catch (e) {
      print('Error setting map boundaries: $e');
    }
  }

  void _toggleBoundaries() {
    setState(() {
      enableBoundaries = !enableBoundaries;
    });

    if (_isMapReady) {
      if (enableBoundaries) {
        _setMapBoundaries();
      } else {
        try {
          controller.limitAreaMap(
            BoundingBox(east: 180, north: 85, south: -85, west: -180),
          );
        } catch (e) {
          print('Error removing boundaries: $e');
        }
      }
    }
  }

  void _centerOnUserLocation() async {
    if (!_isMapReady) return;

    try {
      await controller.currentLocation();
    } catch (e) {
      print('Error centering on user location: $e');
      // Show a snackbar to inform the user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Unable to get your location. Please check location permissions.',
            ),
            backgroundColor: Colors.orange[600],
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    }
  }

  void _refreshData() {
    if (widget.isActive) {
      setState(() {
        _statusMessage = 'Refreshing data...';
      });
      _loadInitialData();
    }
  }

  Color _getStatusColor() {
    if (!_isConnected) return Colors.red;
    if (_buggyLocations.isNotEmpty) return Colors.green;
    return Colors.orange;
  }

  String _getConnectionStatusText() {
    if (!_isConnected) return 'Disconnected';
    if (_buggyLocations.isNotEmpty) return 'Live Updates Active';
    return 'Connected - No Active Buggies';
  }

  @override
  void dispose() {
    _realtimeSubscription?.cancel();
    _buggiesRealtimeSubscription?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'UniTrack Live',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        backgroundColor: Colors.blue[900],
        foregroundColor: Colors.white,
        elevation: 4,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.blue[900]!, Colors.blue[700]!, Colors.cyan[600]!],
            ),
          ),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: const Icon(Icons.refresh, size: 20),
              ),
              onPressed: _refreshData,
              tooltip: 'Refresh Data',
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: enableBoundaries
                      ? Colors.white.withOpacity(0.2)
                      : Colors.orange.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Icon(
                  enableBoundaries ? Icons.lock : Icons.lock_open,
                  size: 20,
                ),
              ),
              onPressed: _toggleBoundaries,
              tooltip: enableBoundaries
                  ? 'Disable Boundaries'
                  : 'Enable Boundaries',
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Enhanced Status Card
              Container(
                width: double.infinity,
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.white, Colors.grey[50]!],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 25,
                      offset: const Offset(0, 5),
                    ),
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 50,
                      offset: const Offset(0, 10),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withOpacity(0.9),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: _getStatusColor(),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: _getStatusColor().withOpacity(0.4),
                                blurRadius: 10,
                                spreadRadius: 3,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusMessage,
                                style: TextStyle(
                                  color: _getStatusColor(),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 20,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _getConnectionStatusText(),
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_buggyLocations.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Colors.blue[600]!, Colors.cyan[500]!],
                              ),
                              borderRadius: BorderRadius.circular(30),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.directions_car,
                                  size: 20,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '${_buggyLocations.length}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    fontSize: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_buggyLocations.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.grey[300]!,
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Icon(
                            Icons.timeline,
                            color: Colors.grey[600],
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Real-time tracking across campus',
                              style: TextStyle(
                                color: Colors.grey[700],
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.green[400],
                              borderRadius: BorderRadius.circular(5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.green.withOpacity(0.4),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.green[600],
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(
                            Icons.gps_fixed,
                            color: Colors.blue[600],
                            size: 22,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Your location is being tracked',
                              style: TextStyle(
                                color: Colors.grey[700],
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.blue[400],
                              borderRadius: BorderRadius.circular(5),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.4),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Map takes up remaining space
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: OSMFlutter(
                    controller: controller,
                    osmOption: OSMOption(
                      zoomOption: const ZoomOption(
                        initZoom: 16,
                        minZoomLevel: 14,
                        maxZoomLevel: 19,
                      ),
                      userTrackingOption: const UserTrackingOption(
                        enableTracking: true,
                        unFollowUser: false,
                      ),
                      userLocationMarker: UserLocationMaker(
                        personMarker: MarkerIcon(
                          iconWidget: Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: Colors.blue[600],
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.3),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                        ),
                        directionArrowMarker: MarkerIcon(
                          iconWidget: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: Colors.blue[600],
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.3),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                      showDefaultInfoWindow: false,
                    ),
                    onMapIsReady: (isReady) async {
                      if (isReady && mounted) {
                        setState(() => _isMapReady = true);
                        await _setMapBoundaries();
                        _loadInitialData();
                      }
                    },
                    onLocationChanged: (myLocation) {},
                    onGeoPointClicked: (geoPoint) async {
                      BuggyLocation? closestBuggy;
                      double minDistance = double.infinity;

                      for (var buggy in _buggyLocations.values) {
                        final distance = _calculateDistance(
                          geoPoint.latitude,
                          geoPoint.longitude,
                          buggy.latitude,
                          buggy.longitude,
                        );

                        if (distance < 50 && distance < minDistance) {
                          minDistance = distance;
                          closestBuggy = buggy;
                        }
                      }

                      if (closestBuggy != null) {
                        _showBuggyDetails(closestBuggy);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.white.withOpacity(0.7),
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  strokeWidth: 4,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _isMapReady && widget.isActive && !_isLoading
          ? FloatingActionButton(
              onPressed: _centerOnUserLocation,
              backgroundColor: Colors.green[600],
              foregroundColor: Colors.white,
              elevation: 8,
              child: const Icon(Icons.gps_fixed, size: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  void _showBuggyDetails(BuggyLocation buggy) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white, Colors.grey[50]!],
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 60,
                offset: const Offset(0, 20),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with gradient
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.blue[600]!, Colors.cyan[500]!],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.directions_car,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Buggy: ${buggy.buggyNumber ?? 'N/A'}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 24,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Content
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    if (buggy.driverName != null) ...[
                      _buildDetailRow(
                        icon: Icons.person_outline,
                        title: 'Driver',
                        value: buggy.driverName!,
                        iconColor: Colors.blue[600]!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (buggy.driverPhone != null &&
                        buggy.driverPhone!.isNotEmpty) ...[
                      _buildDetailRow(
                        icon: Icons.phone_outlined,
                        title: 'Contact',
                        value: buggy.driverPhone!,
                        iconColor: Colors.green[600]!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    _buildDetailRow(
                      icon: Icons.access_time_outlined,
                      title: 'Last Update',
                      value: _formatTime(buggy.updatedAt),
                      iconColor: Colors.purple[600]!,
                    ),
                    const SizedBox(height: 16),
                    _buildDetailRow(
                      icon: Icons.location_on_outlined,
                      title: 'Coordinates',
                      value: '${buggy.latitude}, ${buggy.longitude}',
                      iconColor: Colors.orange[600]!,
                    ),
                  ],
                ),
              ),

              // Action buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(color: Colors.grey[300]!),
                          ),
                        ),
                        child: Text(
                          'Close',
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          controller.moveTo(buggy.geoPoint);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[600],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 4,
                          shadowColor: Colors.blue.withOpacity(0.3),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.my_location, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Locate',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow({
    required IconData icon,
    required String title,
    required String value,
    required Color iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000;
    final double dLat = _toRadians(lat2 - lat1);
    final double dLon = _toRadians(lon2 - lon1);
    final double a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _toRadians(double degrees) {
    return degrees * (math.pi / 180);
  }
}
