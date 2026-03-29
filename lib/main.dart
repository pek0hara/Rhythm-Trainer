import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MetronomeApp());
}

class MetronomeApp extends StatelessWidget {
  const MetronomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Metronome',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const MetronomePage(),
    );
  }
}

class MetronomePage extends StatefulWidget {
  const MetronomePage({super.key});

  @override
  State<MetronomePage> createState() => _MetronomePageState();
}

class _MetronomePageState extends State<MetronomePage>
    with TickerProviderStateMixin {
  static const MethodChannel _methodChannel =
      MethodChannel('com.rhythmtrainer.metronome/control');
  static const EventChannel _eventChannel =
      EventChannel('com.rhythmtrainer.metronome/beats');

  int _bpm = 100;
  bool _isPlaying = false;
  bool _isReady = false;
  bool _showNeedle = true;
  bool _showRipple = true;
  bool _soundEnabled = true;

  final TextEditingController _bpmTextController =
      TextEditingController(text: '100');

  StreamSubscription<dynamic>? _beatSubscription;

  late final AnimationController _needleController;
  late final Animation<double> _needleAngle;
  AnimationController? _flashController;
  late final AnimationController _rippleDriverController;
  final List<DateTime> _rippleStartTimes = [];

  static const int _warmupMeasurements = 0;

  int _tapCount = 0;
  DateTime? _lastTapTime;
  final ValueNotifier<({bool isWarmingUp, double? deviation})> _deviationState =
      ValueNotifier((isWarmingUp: false, deviation: null));
  final List<double> _tapDeviationLog = [];

  @override
  void initState() {
    super.initState();
    _needleController = AnimationController(
      vsync: this,
      duration: _beatDuration,
    );
    _flashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _rippleDriverController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _needleAngle = Tween<double>(
      begin: -math.pi / 4,
      end: math.pi / 4,
    ).animate(
      CurvedAnimation(parent: _needleController, curve: Curves.easeInOut),
    );
    _initClickSound();
  }

  Future<void> _initClickSound() async {
    if (kIsWeb) {
      if (mounted) setState(() => _isReady = true);
      return;
    }
    final Uint8List wav = _buildToneWav(
      frequencyHz: 1000,
      durationMs: 40,
      volume: 0.5,
    );
    await _methodChannel.invokeMethod<void>(
      'prepare',
      Uint8List.fromList(wav),
    );
    if (mounted) setState(() => _isReady = true);
  }

  Duration get _beatDuration =>
      Duration(milliseconds: (60000 / _bpm).round());

  Uint8List _buildToneWav({
    required double frequencyHz,
    required int durationMs,
    required double volume,
  }) {
    const int sampleRate = 44100;
    final int sampleCount = (sampleRate * durationMs / 1000).round();
    final int dataSize = sampleCount * 2;
    final ByteData bytes = ByteData(44 + dataSize);

    void writeAscii(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < sampleCount; i++) {
      final double t = i / sampleRate;
      final double envelope = (1 - (i / sampleCount)).clamp(0.0, 1.0);
      final double sample =
          math.sin(2 * math.pi * frequencyHz * t) * volume * envelope;
      final int value = (sample * 32767).round().clamp(-32768, 32767);
      bytes.setInt16(44 + i * 2, value, Endian.little);
    }

    return bytes.buffer.asUint8List();
  }

  Future<void> _startNative() async {
    await _methodChannel.invokeMethod<void>('start', _bpm.toDouble());
  }

  Future<void> _stopNative() async {
    await _methodChannel.invokeMethod<void>('stop');
  }

  void _restartMetronome() {
    _needleController
      ..duration = _beatDuration
      ..value = 0.5
      ..repeat(reverse: true);
    unawaited(_stopNative().then((_) => _startNative()));
  }

  void _start() {
    _deviationState.value = (isWarmingUp: false, deviation: null);
    setState(() {
      _isPlaying = true;
      _tapCount = 0;
      _lastTapTime = null;
      _tapDeviationLog.clear();
    });

    _needleController
      ..duration = _beatDuration
      ..value = 0.5
      ..repeat(reverse: true);

    unawaited(_startNative());

    _beatSubscription = _eventChannel.receiveBroadcastStream().listen((_) {
      _flashController?.forward(from: 0);
      _rippleStartTimes.add(DateTime.now());
    });
  }

  void _stop() {
    _beatSubscription?.cancel();
    _beatSubscription = null;
    unawaited(_stopNative());
    setState(() => _isPlaying = false);
    _flashController?.stop();
    _rippleStartTimes.clear();
    _needleController
      ..stop()
      ..reset();
  }

  void _onCircleTap() {
    if (!_isPlaying) return;
    final DateTime now = DateTime.now();

    if (_tapCount == 0) {
      // 初回タップ: メトロノーム同期 + 基準時刻記録 + 即座に測定中表示
      _restartMetronome();
      _lastTapTime = now;
      _deviationState.value = (isWarmingUp: true, deviation: null);
    } else if (_lastTapTime != null) {
      final int intervalMs = now.difference(_lastTapTime!).inMilliseconds;
      if (intervalMs > 100) {
        final double tappedBpm = 60000.0 / intervalMs;
        final double deviation = tappedBpm - _bpm;
        // _tapCount==1 が1回目の測定。_tapCount-1 が0始まりの測定インデックス。
        final int measurementIndex = _tapCount - 1;
        if (measurementIndex >= _warmupMeasurements) {
          _tapDeviationLog.add(deviation);
          _deviationState.value = (isWarmingUp: false, deviation: deviation);
        }
      }
      _lastTapTime = now;
    }
    _tapCount++;
  }

  void _applyBpmInput() {
    final int? parsed = int.tryParse(_bpmTextController.text);
    if (parsed != null && parsed >= 40 && parsed <= 240) {
      setState(() => _bpm = parsed);
    } else {
      _bpmTextController.text = _bpm.toString();
    }
  }

  void _togglePlay() {
    if (_isPlaying) {
      _stop();
    } else {
      _start();
    }
  }

  Future<void> _toggleSound() async {
    final bool next = !_soundEnabled;
    setState(() => _soundEnabled = next);
    if (!kIsWeb) {
      await _methodChannel.invokeMethod<void>('setMuted', !next);
    }
  }

  @override
  void dispose() {
    _beatSubscription?.cancel();
    _needleController.dispose();
    _flashController?.dispose();
    _rippleDriverController.dispose();
    _bpmTextController.dispose();
    _deviationState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Metronome',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                    ),
                    IconButton(
                      icon: Icon(_showNeedle ? Icons.straighten : Icons.straighten_outlined),
                      tooltip: _showNeedle ? '針を非表示' : '針を表示',
                      onPressed: () => setState(() => _showNeedle = !_showNeedle),
                    ),
                    IconButton(
                      icon: Icon(_showRipple ? Icons.blur_on : Icons.blur_off),
                      tooltip: _showRipple ? '波を非表示' : '波を表示',
                      onPressed: () => setState(() => _showRipple = !_showRipple),
                    ),
                    IconButton(
                      icon: Icon(_soundEnabled ? Icons.volume_up : Icons.volume_off),
                      tooltip: _soundEnabled ? '音声オフ' : '音声オン',
                      onPressed: _isReady ? _toggleSound : null,
                    ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _bpmTextController,
                        enabled: !_isPlaying,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder()),
                        onSubmitted: (_) {
                          _applyBpmInput();
                          FocusScope.of(context).unfocus();
                        },
                        onTapOutside: (_) {
                          _applyBpmInput();
                          FocusScope.of(context).unfocus();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('BPM',
                        style: Theme.of(context).textTheme.headlineMedium),
                  ],
                ),
                Slider(
                  value: _bpm.toDouble(),
                  min: 40,
                  max: 240,
                  divisions: 200,
                  label: _bpm.toString(),
                  onChanged: _isPlaying
                      ? null
                      : (double value) {
                          setState(() {
                            _bpm = value.round();
                            _bpmTextController.text = _bpm.toString();
                          });
                        },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: <Widget>[
                      if (_showRipple)
                        IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _rippleDriverController,
                            builder: (BuildContext context, Widget? _) {
                              _rippleStartTimes.removeWhere(
                                (DateTime t) =>
                                    DateTime.now().difference(t) > _beatDuration * 2,
                              );
                              return CustomPaint(
                                size: const Size(220, 220),
                                painter: _RipplePainter(
                                  startTimes: List<DateTime>.from(_rippleStartTimes),
                                  rippleDuration: _beatDuration,
                                  color: Theme.of(context).colorScheme.secondary,
                                  maxRadius: 110,
                                  circleRadius: 60,
                                  inward: true,
                                ),
                              );
                            },
                          ),
                        ),
                      Listener(
                        onPointerDown: (_) => _onCircleTap(),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 168,
                          height: 168,
                          color: Colors.transparent,
                          child: Center(
                            child: AnimatedBuilder(
                              animation: _flashController ?? _needleController,
                              builder: (BuildContext context, Widget? _) {
                                final Color color = Color.lerp(
                                  Theme.of(context).colorScheme.primaryContainer,
                                  Theme.of(context).colorScheme.primary,
                                  _flashController?.value ?? 0.0,
                                )!;
                                return Container(
                                  width: 120,
                                  height: 120,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      if (_showNeedle)
                        IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _needleAngle,
                            builder: (BuildContext context, Widget? child) {
                              return Transform.rotate(
                                angle: _needleAngle.value,
                                alignment: Alignment.bottomCenter,
                                child: child,
                              );
                            },
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                minHeight: 0,
                                maxHeight: double.infinity,
                                child: Transform.translate(
                                  offset: const Offset(0, -250),
                                  child: Container(
                                    width: 8,
                                    height: 450,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.secondary,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      IgnorePointer(
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _isReady ? _togglePlay : null,
                  icon: Icon(
                      _isPlaying ? Icons.stop : Icons.play_arrow,
                      size: 32),
                  label: Text(
                    _isPlaying ? '停止' : '再生',
                    style: const TextStyle(fontSize: 20),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                  ),
                ),
                const SizedBox(height: 16),
                ValueListenableBuilder(
                  valueListenable: _deviationState,
                  builder: (BuildContext context,
                      ({bool isWarmingUp, double? deviation}) state, _) {
                    if (!_isPlaying) return const SizedBox.shrink();
                    if (state.isWarmingUp) {
                      return Text(
                        'リズム測定中...',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Colors.grey,
                            ),
                      );
                    }
                    final double? d = state.deviation;
                    if (d == null) return const SizedBox.shrink();
                    return Text(
                      '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} BPM',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: d.abs() < 2
                                ? Colors.green
                                : d.abs() < 5
                                    ? Colors.orange
                                    : Colors.red,
                          ),
                    );
                  },
                ),
                if (!_isPlaying && _tapDeviationLog.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('タップログ'),
                        content: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Builder(builder: (_) {
                                final int total = _tapDeviationLog.length;
                                final int green = _tapDeviationLog.where((double d) => d.abs() < 2).length;
                                final int orange = _tapDeviationLog.where((double d) => d.abs() >= 2 && d.abs() < 5).length;
                                final int red = total - green - orange;
                                String pct(int n) => '${(n / total * 100).round()}%';
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: <Widget>[
                                      Text('🟢 $green (${pct(green)})', style: const TextStyle(color: Colors.green)),
                                      Text('🟡 $orange (${pct(orange)})', style: const TextStyle(color: Colors.orange)),
                                      Text('🔴 $red (${pct(red)})', style: const TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                );
                              }),
                              ...List<Widget>.generate(
                                  _tapDeviationLog.length, (int i) {
                                final double d = _tapDeviationLog[i];
                                return Text(
                                  '#${i + 1}:  ${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} BPM',
                                  style: TextStyle(
                                    color: d.abs() < 2
                                        ? Colors.green
                                        : d.abs() < 5
                                            ? Colors.orange
                                            : Colors.red,
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('閉じる'),
                          ),
                        ],
                      ),
                    ),
                    icon: const Icon(Icons.list_alt),
                    label: const Text('ログを見る'),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.startTimes,
    required this.rippleDuration,
    required this.color,
    required this.maxRadius,
    required this.circleRadius,
    this.inward = false,
  });

  final List<DateTime> startTimes;
  final Duration rippleDuration;
  final Color color;
  final double maxRadius;
  final double circleRadius;
  final bool inward;

  @override
  void paint(Canvas canvas, Size size) {
    final DateTime now = DateTime.now();
    final Offset center = Offset(size.width / 2, size.height / 2);
    final int durationMs = rippleDuration.inMilliseconds;

    for (final DateTime start in startTimes) {
      final int elapsedMs = now.difference(start).inMilliseconds;
      if (elapsedMs > durationMs) continue;
      final double progress = elapsedMs / durationMs;
      final double radius;
      final double opacity;
      final double strokeWidth;
      if (inward) {
        // 外側(暗・細)→中央(明・太): 到達瞬間が最も鮮明でビートと重なる
        radius = maxRadius * (1.0 - progress);
        opacity = progress * 0.7;
        strokeWidth = 2.0 + progress * 4.0;
      } else {
        radius = progress * maxRadius;
        opacity = (1.0 - progress) * 0.55;
        strokeWidth = 3.0;
      }
      final Color ringColor =
          radius <= circleRadius ? Colors.white : color;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = ringColor.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) => true;
}
