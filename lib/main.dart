import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Car 360 Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.orange,
        useMaterial3: true,
      ),
      home: const ComparisonScreen(),
    );
  }
}

// ============================================================
// Comparison Screen - 2 tabs to compare RAM usage
// ============================================================
class ComparisonScreen extends StatefulWidget {
  const ComparisonScreen({super.key});

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  int _selectedIndex = 0;

  // Keys to force rebuild when switching tabs
  final _fullSizeKey = GlobalKey<_CarViewer360State>();
  final _resizedKey = GlobalKey<_CarViewer360State>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          CarViewer360(
            key: _fullSizeKey,
            title: 'Full Size (no resize)',
            useResize: false,
          ),
          CarViewer360(
            key: _resizedKey,
            title: 'ResizeImage (optimized)',
            useResize: true,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_size_select_large),
            label: 'Full Size',
          ),
          NavigationDestination(
            icon: Icon(Icons.compress),
            label: 'Resized',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Shared 360 Viewer Widget - configurable resize behavior
// ============================================================
class CarViewer360 extends StatefulWidget {
  final String title;
  final bool useResize;

  const CarViewer360({
    super.key,
    required this.title,
    required this.useResize,
  });

  @override
  State<CarViewer360> createState() => _CarViewer360State();
}

class _CarViewer360State extends State<CarViewer360>
    with SingleTickerProviderStateMixin {
  static const int _totalFrames = 72;
  static const double _pixelsPerFrame = 4.0;
  static const double _qualityRatio = 0.7;


  final List<String> _imageUrls = List.generate(
    _totalFrames,
    (index) =>
        'https://scaleflex.cloudimg.io/v7/demo/suv-orange-car-360/orange-${index + 1}.jpg',
  );

  final List<ui.Image?> _frames = List.filled(_totalFrames, null);
  int _loadedCount = 0;
  bool _isPreloading = true;

  int _currentFrame = 0;
  double _position = 0;
  bool _isDragging = false;

  late Ticker _inertiaTicker;
  double _flingVelocity = 0;

  // Memory tracking
  int _totalImageBytes = 0;
  Timer? _memoryTimer;
  String _dartHeapUsage = '...';

  @override
  void initState() {
    super.initState();
    _inertiaTicker = createTicker(_onInertiaTick)..start();
    _loadAllImages();
    _startMemoryTracking();
  }

  void _startMemoryTracking() {
    _memoryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _updateMemoryInfo();
    });
  }

  void _updateMemoryInfo() {
    // Calculate image memory from decoded frames
    int bytes = 0;
    for (final frame in _frames) {
      if (frame != null) {
        // RGBA = 4 bytes per pixel
        bytes += frame.width * frame.height * 4;
      }
    }
    if (mounted) {
      setState(() {
        _totalImageBytes = bytes;
        _dartHeapUsage = '${(_totalImageBytes / 1024 / 1024).toStringAsFixed(1)} MB';
      });
    }
  }

  Future<void> _loadAllImages() async {
    const batchSize = 12;
    for (int i = 0; i < _imageUrls.length; i += batchSize) {
      if (!mounted) return;
      final end = (i + batchSize).clamp(0, _imageUrls.length);
      await Future.wait(
        List.generate(end - i, (j) => _resolveImage(i + j)),
      );
      _updateMemoryInfo();
    }
    if (mounted) {
      setState(() => _isPreloading = false);
    }
  }

  Future<void> _resolveImage(int index) async {
    final completer = Completer<void>();

    ImageProvider provider;
    if (widget.useResize) {
      // Use physical pixels (logical * devicePixelRatio) for retina sharpness
      // e.g. iPhone: 390 logical * 3x = 1170 physical pixels
      // Still much smaller than source image if source > 1170px
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final targetWidth = (view.physicalSize.width * _qualityRatio).toInt();
      provider = ResizeImage(
        NetworkImage(_imageUrls[index]),
        width: targetWidth,
        allowUpscaling: false,
      );
    } else {
      provider = NetworkImage(_imageUrls[index]);
    }

    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        _frames[index] = info.image.clone();
        info.image.dispose();
        if (mounted) setState(() => _loadedCount++);
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
      onError: (error, _) {
        if (mounted) setState(() => _loadedCount++);
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete();
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  void _updateFrame() {
    _position = _position % _totalFrames;
    if (_position < 0) _position += _totalFrames;

    final newFrame = _position.round() % _totalFrames;
    if (newFrame != _currentFrame) {
      _currentFrame = newFrame;
      (context as Element).markNeedsBuild();
    }
  }

  void _onInertiaTick(Duration elapsed) {
    if (_isDragging || _flingVelocity.abs() < 10) return;

    const dt = 1.0 / 60.0;
    _position -= (_flingVelocity * dt) / _pixelsPerFrame;
    _flingVelocity *= 0.95;

    if (_flingVelocity.abs() < 10) _flingVelocity = 0;
    _updateFrame();
  }

  void _onDragStart(DragStartDetails details) {
    _isDragging = true;
    _flingVelocity = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _position -= details.delta.dx / _pixelsPerFrame;
    _updateFrame();
  }

  void _onDragEnd(DragEndDetails details) {
    _isDragging = false;
    _flingVelocity = details.velocity.pixelsPerSecond.dx;
  }

  @override
  void dispose() {
    _memoryTimer?.cancel();
    _inertiaTicker.dispose();
    for (final frame in _frames) {
      frame?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        centerTitle: true,
      ),
      body: _isPreloading ? _buildLoadingScreen() : _buildViewer(),
    );
  }

  Widget _buildLoadingScreen() {
    final progress = _loadedCount / _totalFrames;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(value: progress, strokeWidth: 6),
                Text(
                  '${(progress * 100).round()}%',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Loading $_loadedCount / $_totalFrames',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Image RAM: $_dartHeapUsage',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewer() {
    // Get first frame dimensions for display
    final firstFrame = _frames[0];
    final frameSize = firstFrame != null
        ? '${firstFrame.width} x ${firstFrame.height}'
        : '...';

    return Column(
      children: [
        // Memory info bar
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: widget.useResize ? Colors.green[50] : Colors.red[50],
          child: Row(
            children: [
              Icon(
                Icons.memory,
                size: 18,
                color: widget.useResize ? Colors.green[700] : Colors.red[700],
              ),
              const SizedBox(width: 8),
              Text(
                'Image RAM: $_dartHeapUsage',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color:
                      widget.useResize ? Colors.green[700] : Colors.red[700],
                ),
              ),
              const Spacer(),
              Text(
                'Frame: $frameSize',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RepaintBoundary(
            child: GestureDetector(
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: Container(
                color: Colors.grey[100],
                alignment: Alignment.center,
                child: _CarFramePainter(image: _frames[_currentFrame]),
              ),
            ),
          ),
        ),
        _FrameInfo(
          currentFrame: _currentFrame,
          totalFrames: _totalFrames,
        ),
      ],
    );
  }
}

// ============================================================
// Custom RenderObject for zero-overhead image rendering
// ============================================================
class _CarFramePainter extends LeafRenderObjectWidget {
  final ui.Image? image;

  const _CarFramePainter({this.image});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _CarFrameRenderObject(image);
  }

  @override
  void updateRenderObject(
      BuildContext context, _CarFrameRenderObject renderObject) {
    renderObject.image = image;
  }
}

class _CarFrameRenderObject extends RenderBox {
  ui.Image? _image;

  _CarFrameRenderObject(this._image);

  set image(ui.Image? value) {
    if (_image == value) return;
    _image = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final img = _image;
    if (img == null) return;

    final canvas = context.canvas;
    final srcSize = Size(img.width.toDouble(), img.height.toDouble());
    final dstSize = size;

    final scale = (dstSize.width / srcSize.width)
        .clamp(0, dstSize.height / srcSize.height)
        .toDouble();
    final scaledWidth = srcSize.width * scale;
    final scaledHeight = srcSize.height * scale;
    final dx = offset.dx + (dstSize.width - scaledWidth) / 2;
    final dy = offset.dy + (dstSize.height - scaledHeight) / 2;

    canvas.drawImageRect(
      img,
      Offset.zero & srcSize,
      Rect.fromLTWH(dx, dy, scaledWidth, scaledHeight),
      Paint()..filterQuality = FilterQuality.low,
    );
  }
}

// ============================================================
// Frame info panel
// ============================================================
class _FrameInfo extends StatelessWidget {
  final int currentFrame;
  final int totalFrames;

  const _FrameInfo({required this.currentFrame, required this.totalFrames});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Frame ${currentFrame + 1} / $totalFrames',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text(
                '${(currentFrame / totalFrames * 360).round()}°',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: currentFrame / (totalFrames - 1),
            backgroundColor: Colors.grey[300],
          ),
          const SizedBox(height: 12),
          Text(
            'Swipe to rotate',
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
        ],
      ),
    );
  }
}
