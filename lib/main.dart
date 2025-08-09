import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:collection';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(AntTrackingApp(cameras: cameras));
}

class AntTrackingApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const AntTrackingApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ant Tracker',
      theme: ThemeData(
        primarySwatch: Colors.brown,
        brightness: Brightness.dark,
      ),
      home: AntTracker(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}

class DetectedAnt {
  final Offset position;
  final DateTime timestamp;
  final double confidence;

  DetectedAnt({
    required this.position,
    required this.timestamp,
    required this.confidence,
  });
}

class AntTrack {
  final List<DetectedAnt> positions;
  final Color color;
  DateTime lastSeen;

  AntTrack({required this.color}) 
    : positions = [],
      lastSeen = DateTime.now();

  void addPosition(DetectedAnt ant) {
    positions.add(ant);
    lastSeen = ant.timestamp;
    
    // Keep only last 30 positions for performance
    if (positions.length > 30) {
      positions.removeAt(0);
    }
  }

  double get speed {
    if (positions.length < 2) return 0.0;
    
    final recent = positions.length > 5 ? positions.sublist(positions.length - 5) : positions;
    double totalDistance = 0.0;
    int totalTime = 0;

    for (int i = 1; i < recent.length; i++) {
      final distance = _distance(recent[i-1].position, recent[i].position);
      final timeDiff = recent[i].timestamp.difference(recent[i-1].timestamp).inMilliseconds;
      totalDistance += distance * 0.1; // Convert pixels to mm (approximate)
      totalTime += timeDiff;
    }

    return totalTime > 0 ? (totalDistance / totalTime) * 1000 : 0.0; // mm/s
  }

  double get totalDistance {
    if (positions.length < 2) return 0.0;
    
    double total = 0.0;
    for (int i = 1; i < positions.length; i++) {
      total += _distance(positions[i-1].position, positions[i].position) * 0.1;
    }
    return total;
  }

  double _distance(Offset p1, Offset p2) {
    return math.sqrt(math.pow(p2.dx - p1.dx, 2) + math.pow(p2.dy - p1.dy, 2));
  }
}

class AntTracker extends StatefulWidget {
  final List<CameraDescription> cameras;

  const AntTracker({super.key, required this.cameras});

  @override
  State<AntTracker> createState() => _AntTrackerState();
}

class _AntTrackerState extends State<AntTracker> {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isTracking = false;
  
  List<AntTrack> _tracks = [];
  Timer? _detectionTimer;
  img.Image? _previousFrame;
  
  // Detection parameters
  final double _pixelToMmRatio = 0.1; // Approximate conversion
  final int _maxTracks = 3;
  final double _minMovement = 2.0; // Minimum pixel movement to consider
  final int _maxTrackAge = 30; // Frames before removing track

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;

    final permission = await Permission.camera.request();
    if (permission != PermissionStatus.granted) return;

    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium, // Use medium for better performance
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      print('Camera error: $e');
    }
  }

  void _startTracking() {
    if (!_isInitialized) return;
    
    setState(() {
      _isTracking = true;
      _tracks.clear();
    });

    _detectionTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      _captureAndDetect();
    });
  }

  void _stopTracking() {
    setState(() {
      _isTracking = false;
    });
    _detectionTimer?.cancel();
  }

  Future<void> _captureAndDetect() async {
    if (!_isTracking || _controller == null) return;

    try {
      final image = await _controller!.takePicture();
      final bytes = await image.readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      
      if (decodedImage != null) {
        final detectedAnts = await _detectMovingObjects(decodedImage);
        _updateTracks(detectedAnts);
      }
    } catch (e) {
      print('Detection error: $e');
    }
  }

  Future<List<DetectedAnt>> _detectMovingObjects(img.Image currentFrame) async {
    final List<DetectedAnt> detections = [];
    
    if (_previousFrame == null) {
      _previousFrame = currentFrame;
      return detections;
    }

    // Simple motion detection using frame difference
    final diff = _computeFrameDifference(_previousFrame!, currentFrame);
    final blobs = _findBlobs(diff);
    
    final now = DateTime.now();
    for (final blob in blobs) {
      // Filter by size (ants are small but not too small)
      if (blob.area > 10 && blob.area < 500) {
        detections.add(DetectedAnt(
          position: blob.center,
          timestamp: now,
          confidence: math.min(blob.area / 50.0, 1.0),
        ));
      }
    }

    _previousFrame = currentFrame;
    return detections;
  }

  img.Image _computeFrameDifference(img.Image prev, img.Image curr) {
    final width = math.min(prev.width, curr.width);
    final height = math.min(prev.height, curr.height);
    final diff = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final prevPixel = prev.getPixel(x, y);
        final currPixel = curr.getPixel(x, y);
        
        // Convert to grayscale and compute difference
        final prevGray = (prevPixel.r * 0.299 + prevPixel.g * 0.587 + prevPixel.b * 0.114).round();
        final currGray = (currPixel.r * 0.299 + currPixel.g * 0.587 + currPixel.b * 0.114).round();
        final diffValue = (currGray - prevGray).abs();
        
        // Threshold for motion detection
        final thresholdValue = diffValue > 30 ? 255 : 0;
        diff.setPixelRgba(x, y, thresholdValue, thresholdValue, thresholdValue, 255);
      }
    }

    return diff;
  }

  List<Blob> _findBlobs(img.Image binaryImage) {
    final List<Blob> blobs = [];
    final visited = List.generate(
      binaryImage.height, 
      (i) => List.filled(binaryImage.width, false),
    );

    for (int y = 0; y < binaryImage.height; y++) {
      for (int x = 0; x < binaryImage.width; x++) {
        if (!visited[y][x] && _isWhitePixel(binaryImage, x, y)) {
          final blob = _floodFill(binaryImage, visited, x, y);
          if (blob.area > 5) { // Minimum blob size
            blobs.add(blob);
          }
        }
      }
    }

    return blobs;
  }

  bool _isWhitePixel(img.Image image, int x, int y) {
    final pixel = image.getPixel(x, y);
    return pixel.r > 128; // Binary threshold
  }

  Blob _floodFill(img.Image image, List<List<bool>> visited, int startX, int startY) {
    final List<Offset> pixels = [];
    final Queue<Offset> queue = Queue<Offset>();
    
    queue.add(Offset(startX.toDouble(), startY.toDouble()));
    
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final x = current.dx.toInt();
      final y = current.dy.toInt();
      
      if (x < 0 || x >= image.width || y < 0 || y >= image.height ||
          visited[y][x] || !_isWhitePixel(image, x, y)) {
        continue;
      }
      
      visited[y][x] = true;
      pixels.add(current);
      
      // Add 4-connected neighbors
      queue.add(Offset((x + 1).toDouble(), y.toDouble()));
      queue.add(Offset((x - 1).toDouble(), y.toDouble()));
      queue.add(Offset(x.toDouble(), (y + 1).toDouble()));
      queue.add(Offset(x.toDouble(), (y - 1).toDouble()));
    }
    
    return Blob(pixels);
  }

  void _updateTracks(List<DetectedAnt> detections) {
    final now = DateTime.now();
    
    // Remove old tracks
    _tracks.removeWhere((track) => 
      now.difference(track.lastSeen).inSeconds > 5
    );

    // Match detections to existing tracks
    for (final detection in detections) {
      AntTrack? bestTrack;
      double bestDistance = double.infinity;
      
      for (final track in _tracks) {
        if (track.positions.isNotEmpty) {
          final lastPos = track.positions.last.position;
          final distance = _calculateDistance(lastPos, detection.position);
          
          if (distance < 50 && distance < bestDistance) { // Max 50 pixel association
            bestDistance = distance;
            bestTrack = track;
          }
        }
      }
      
      if (bestTrack != null) {
        // Update existing track
        bestTrack.addPosition(detection);
      } else if (_tracks.length < _maxTracks) {
        // Create new track
        final newTrack = AntTrack(
          color: _getTrackColor(_tracks.length),
        );
        newTrack.addPosition(detection);
        _tracks.add(newTrack);
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  Color _getTrackColor(int index) {
    final colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
    ];
    return colors[index % colors.length];
  }

  double _calculateDistance(Offset p1, Offset p2) {
    return math.sqrt(math.pow(p2.dx - p1.dx, 2) + math.pow(p2.dy - p1.dy, 2));
  }

  @override
  void dispose() {
    _controller?.dispose();
    _detectionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Ant Tracker'),
        backgroundColor: Colors.brown,
      ),
      body: _isInitialized
          ? Stack(
              children: [
                // Camera preview
                Positioned.fill(
                  child: CameraPreview(_controller!),
                ),
                
                // Tracking overlay
                Positioned.fill(
                  child: CustomPaint(
                    painter: TrackingPainter(_tracks),
                  ),
                ),

                // Status indicator
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isTracking ? Icons.track_changes : Icons.stop,
                          color: _isTracking ? Colors.green : Colors.red,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isTracking ? 'Tracking' : 'Stopped',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),

                // Metrics display
                if (_tracks.isNotEmpty)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Ants: ${_tracks.length}',
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          for (int i = 0; i < _tracks.length; i++)
                            Text(
                              'Ant ${i + 1}: ${_tracks[i].speed.toStringAsFixed(1)} mm/s',
                              style: TextStyle(
                                color: _tracks[i].color,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                // Controls
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      FloatingActionButton(
                        onPressed: _isTracking ? _stopTracking : _startTracking,
                        backgroundColor: _isTracking ? Colors.red : Colors.green,
                        child: Icon(_isTracking ? Icons.stop : Icons.play_arrow),
                      ),
                      FloatingActionButton(
                        onPressed: () {
                          setState(() {
                            _tracks.clear();
                          });
                        },
                        backgroundColor: Colors.orange,
                        child: const Icon(Icons.clear),
                      ),
                      FloatingActionButton(
                        onPressed: () => _showStats(),
                        backgroundColor: Colors.blue,
                        child: const Icon(Icons.info),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(
              child: CircularProgressIndicator(),
            ),
    );
  }

  void _showStats() {
    if (_tracks.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tracking Statistics'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < _tracks.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ant ${i + 1}:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _tracks[i].color,
                      ),
                    ),
                    Text('Speed: ${_tracks[i].speed.toStringAsFixed(2)} mm/s'),
                    Text('Distance: ${_tracks[i].totalDistance.toStringAsFixed(2)} mm'),
                    Text('Points: ${_tracks[i].positions.length}'),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class Blob {
  final List<Offset> pixels;

  Blob(this.pixels);

  int get area => pixels.length;

  Offset get center {
    if (pixels.isEmpty) return Offset.zero;
    
    double sumX = 0;
    double sumY = 0;
    
    for (final pixel in pixels) {
      sumX += pixel.dx;
      sumY += pixel.dy;
    }
    
    return Offset(sumX / pixels.length, sumY / pixels.length);
  }
}

class TrackingPainter extends CustomPainter {
  final List<AntTrack> tracks;

  TrackingPainter(this.tracks);

  @override
  void paint(Canvas canvas, Size size) {
    for (final track in tracks) {
      if (track.positions.isEmpty) continue;

      // Draw path
      if (track.positions.length > 1) {
        final pathPaint = Paint()
          ..color = track.color.withOpacity(0.7)
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke;

        final path = ui.Path();
        path.moveTo(
          track.positions.first.position.dx,
          track.positions.first.position.dy,
        );

        for (int i = 1; i < track.positions.length; i++) {
          path.lineTo(
            track.positions[i].position.dx,
            track.positions[i].position.dy,
          );
        }

        canvas.drawPath(path, pathPaint);
      }

      // Draw current position
      final currentPos = track.positions.last.position;
      final antPaint = Paint()
        ..color = track.color
        ..style = PaintingStyle.fill;

      canvas.drawCircle(currentPos, 6, antPaint);

      // Draw speed indicator
      if (track.speed > 0) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: '${track.speed.toStringAsFixed(1)}mm/s',
            style: TextStyle(
              color: track.color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas, 
          Offset(currentPos.dx + 8, currentPos.dy - 8),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}