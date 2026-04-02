import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

enum VisualMode { metronome, wave, flash }

class RhythmPattern {
  const RhythmPattern({
    required this.id,
    required this.name,
    required this.intervals,
    this.isPreset = false,
  });
  final String id;
  final String name;
  final List<double> intervals; // 拍単位。合計 = 1小節
  final bool isPreset;
}

const List<RhythmPattern> kRhythmPresets = <RhythmPattern>[
  RhythmPattern(id: 'quarter', name: '4分', intervals: <double>[1, 1, 1, 1], isPreset: true),
  RhythmPattern(id: 'preset_a', name: '定番A', intervals: <double>[1, 1, 0.5, 0.5, 0.5, 0.5], isPreset: true),
  RhythmPattern(id: 'preset_b', name: '定番B', intervals: <double>[1, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], isPreset: true),
  RhythmPattern(id: 'preset_c', name: '定番C', intervals: <double>[1, 0.5, 1, 0.5, 0.5, 0.5], isPreset: true),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const MetronomeApp());
}

class MetronomeApp extends StatelessWidget {
  const MetronomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rhythm Checker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        textTheme: GoogleFonts.notoSansJpTextTheme(),
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
  VisualMode _visualMode = VisualMode.metronome;
  bool _soundEnabled = true;
  bool _isTapping = false;

  final TextEditingController _bpmTextController =
      TextEditingController(text: '100');

  StreamSubscription<dynamic>? _beatSubscription;

  late final AnimationController _needleController;
  late final Animation<double> _needleAngle;
  AnimationController? _flashController;
  late final AnimationController _rippleDriverController;
  late final AnimationController _patternProgressController;
  final List<DateTime> _rippleStartTimes = [];

  static const int _warmupMeasurements = 0;

  RhythmPattern _selectedPattern = kRhythmPresets.first;
  final ValueNotifier<int> _patternIndexNotifier = ValueNotifier<int>(0);
  Timer? _patternTimer;

  int _tapCount = 0;
  DateTime? _syncTime;
  DateTime? _lastMeasuredTapTime;
  int _lastMeasuredExpectedMs = 0;
  double? _sessionAvgBpm;
  final ValueNotifier<({bool isWarmingUp, bool isTooFast, double? ratio, double? bpm, int? deviationMs})>
      _deviationState =
      ValueNotifier((isWarmingUp: false, isTooFast: false, ratio: null, bpm: null, deviationMs: null));
  final List<({double ratio, double bpm, int ms})> _tapDeviationLog = [];

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
    _patternProgressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
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

  void _startPatternClock() {
    _patternTimer?.cancel();
    final int pi = _patternIndexNotifier.value;
    final int ms =
        (_selectedPattern.intervals[pi] * _beatDuration.inMilliseconds).round();
    _patternProgressController.duration = Duration(milliseconds: ms);
    _patternProgressController.forward(from: 0.0);
    _patternTimer = Timer(Duration(milliseconds: ms), () {
      if (!_isPlaying) return;
      _patternIndexNotifier.value =
          (pi + 1) % _selectedPattern.intervals.length;
      _startPatternClock();
    });
  }

  void _restartMetronome() {
    _needleController
      ..duration = _beatDuration
      ..value = 0.5
      ..repeat(reverse: true);
    unawaited(_stopNative().then((_) => _startNative()));
  }

  void _start() {
    _deviationState.value = (isWarmingUp: false, isTooFast: false, ratio: null, bpm: null, deviationMs: null);
    _patternIndexNotifier.value = 0;
    setState(() {
      _isPlaying = true;
      _tapCount = 0;
      _syncTime = null;
      _lastMeasuredTapTime = null;
      _lastMeasuredExpectedMs = 0;
      _tapDeviationLog.clear();
    });

    _needleController
      ..duration = _beatDuration
      ..value = 0.5
      ..repeat(reverse: true);

    unawaited(_startNative());

    _beatSubscription = _eventChannel.receiveBroadcastStream().listen((_) {
      if (_visualMode == VisualMode.flash) {
        _flashController?.forward(from: 0);
      }
      if (_visualMode == VisualMode.wave) {
        _rippleStartTimes.add(DateTime.now());
      }
    });
  }

  void _stop() {
    _beatSubscription?.cancel();
    _beatSubscription = null;
    unawaited(_stopNative());
    setState(() => _isPlaying = false);
    _flashController?.stop();
    _rippleStartTimes.clear();
    _patternTimer?.cancel();
    _patternProgressController.stop();
    _patternProgressController.value = 0.0;
    _patternIndexNotifier.value = 0;
    // スタート〜最後のタップ間の実測BPMを確定
    // 拍数 = タップ数 × (パターン合計拍数 / パターンタップ数)
    final int measuredTaps = _tapCount - 1;
    if (_syncTime != null && _lastMeasuredTapTime != null && measuredTaps > 0) {
      final int elapsedMs = _lastMeasuredTapTime!.difference(_syncTime!).inMilliseconds;
      final double totalBeats = _selectedPattern.intervals.fold(0.0, (double s, double v) => s + v);
      final double beatsPerTap = totalBeats / _selectedPattern.intervals.length;
      _sessionAvgBpm = measuredTaps * beatsPerTap * 60000.0 / elapsedMs;
    } else {
      _sessionAvgBpm = null;
    }
    _syncTime = null;
    _lastMeasuredTapTime = null;
    _lastMeasuredExpectedMs = 0;
    _needleController
      ..stop()
      ..reset();
  }

  /// 初回タップを t=0 として、経過時間 [elapsedMs] に最も近い拍を返す。
  /// 返値: 期待拍時刻(ms) と、その拍に到達するインターバル幅(ms)。
  ({int expectedMs, double intervalMs}) _nearestBeat(int elapsedMs) {
    final double beatMs = _beatDuration.inMilliseconds.toDouble();
    final List<double> intervals = _selectedPattern.intervals;
    final double totalPatternMs =
        intervals.fold(0.0, (double s, double v) => s + v) * beatMs;

    double t = 0.0;
    double bestT = 0.0;
    double bestIntervalMs = intervals[0] * beatMs;
    double bestDiff = double.infinity;

    // t=0 はシンク拍なので除外。各インターバルを積み上げて次の拍を候補にする。
    final int maxReps = (elapsedMs / totalPatternMs + 2).ceil().clamp(2, 200);
    for (int rep = 0; rep < maxReps; rep++) {
      for (int i = 0; i < intervals.length; i++) {
        t += intervals[i] * beatMs;
        final double diff = (t - elapsedMs).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestT = t;
          bestIntervalMs = intervals[i] * beatMs;
        }
      }
    }
    return (expectedMs: bestT.round(), intervalMs: bestIntervalMs);
  }

  void _onCircleTap() {
    if (!_isPlaying) return;
    final DateTime now = DateTime.now();

    if (_tapCount == 0) {
      // 初回タップ: メトロノーム同期 + パターンクロック起動
      _restartMetronome();
      _syncTime = now;
      _lastMeasuredTapTime = now;
      _lastMeasuredExpectedMs = 0;
      _patternIndexNotifier.value = 0;
      _deviationState.value = (isWarmingUp: true, isTooFast: false, ratio: null, bpm: null, deviationMs: null);
      _startPatternClock();
    } else if (_syncTime != null && _lastMeasuredTapTime != null) {
      // 絶対時間でどの拍かを特定 → 1拍押し損ねても位置を見失わない
      final int elapsedMs = now.difference(_syncTime!).inMilliseconds;
      final ({int expectedMs, double intervalMs}) nearest = _nearestBeat(elapsedMs);

      // 偏差は「前回タップからの実IOI」で測る → リズム感を反映
      final int actualIoi = now.difference(_lastMeasuredTapTime!).inMilliseconds;
      final int expectedIoi = nearest.expectedMs - _lastMeasuredExpectedMs;

      // 同じ拍への二重スナップは無効タップ
      if (expectedIoi <= 0) {
        _deviationState.value = (isWarmingUp: false, isTooFast: true, ratio: null, bpm: null, deviationMs: null);
        _tapCount++;
        return;
      }

      final int deviationMs = actualIoi - expectedIoi;
      final double ratio = deviationMs / expectedIoi;
      final double bpmDeviation =
          60000.0 / actualIoi - 60000.0 / expectedIoi;

      _lastMeasuredTapTime = now;
      _lastMeasuredExpectedMs = nearest.expectedMs;

      final int measurementIndex = _tapCount - 1;
      if (measurementIndex >= _warmupMeasurements) {
        _tapDeviationLog.add((ratio: ratio, bpm: bpmDeviation, ms: deviationMs));
        _deviationState.value = (
          isWarmingUp: false,
          isTooFast: false,
          ratio: ratio,
          bpm: bpmDeviation,
          deviationMs: deviationMs,
        );
      }
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

  void _showPatternSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('リズムパターン',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 16),
                Column(
                  children: kRhythmPresets.map((RhythmPattern p) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PatternCard(
                        pattern: p,
                        isSelected: _selectedPattern.id == p.id,
                        onTap: () {
                          setState(() {
                            _selectedPattern = p;
                            _syncTime = null;
                            _lastMeasuredTapTime = null;
                            _lastMeasuredExpectedMs = 0;
                            _patternIndexNotifier.value = 0;
                          });
                          Navigator.of(ctx).pop();
                        },
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showTapLogDialog(BuildContext context) {
    final List<({double ratio, double bpm, int ms})> log = _tapDeviationLog;
    final int total = log.length;
    final int nGreen = log.where((e) => e.ratio.abs() < 0.05).length;
    final int nOrange =
        log.where((e) => e.ratio.abs() >= 0.05 && e.ratio.abs() < 0.10).length;
    final int nRed = total - nGreen - nOrange;
    String pct(int n) => '${(n / total * 100).round()}%';

    final double avgBpm = _sessionAvgBpm ?? _bpm.toDouble();
    final double avgMs = log.fold(0.0, (s, e) => s + e.ms) / total;
    final double avgAbsMs = log.fold(0.0, (s, e) => s + e.ms.abs()) / total;

    Color devColor(double r) => r.abs() < 0.05
        ? Colors.green.shade600
        : r.abs() < 0.10
            ? Colors.orange.shade700
            : Colors.red.shade600;

    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        final ColorScheme cs = Theme.of(ctx).colorScheme;
        final TextTheme tt = Theme.of(ctx).textTheme;
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 8, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.bar_chart_rounded, color: cs.primary),
                    const SizedBox(width: 8),
                    Text('タップログ', style: tt.titleLarge),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(
                    children: <Widget>[
                      _StatChip(
                          label: '±2以内',
                          count: nGreen,
                          pct: pct(nGreen),
                          color: Colors.green.shade600),
                      const SizedBox(width: 8),
                      _StatChip(
                          label: '±5以内',
                          count: nOrange,
                          pct: pct(nOrange),
                          color: Colors.orange.shade700),
                      const SizedBox(width: 8),
                      _StatChip(
                          label: '±5超',
                          count: nRed,
                          pct: pct(nRed),
                          color: Colors.red.shade600),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(
                    children: <Widget>[
                      _SummaryCell(label: '平均BPM', value: avgBpm.toStringAsFixed(1),
                          color: cs.onSurface),
                      const SizedBox(width: 12),
                      _SummaryCell(label: '傾向',
                          value: '${avgMs >= 0 ? '+' : ''}${avgMs.toStringAsFixed(1)}ms',
                          color: avgMs.abs() < 20 ? Colors.green.shade600 : Colors.orange.shade700),
                      const SizedBox(width: 12),
                      _SummaryCell(label: '誤差',
                          value: '${avgAbsMs.toStringAsFixed(1)}ms',
                          color: avgAbsMs < 20 ? Colors.green.shade600 : Colors.orange.shade700),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.separated(
                    itemCount: log.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (_, int i) {
                      final double r = log[i].ratio;
                      final double d = log[i].bpm;
                      final int ms = log[i].ms;
                      final Color c = devColor(r);
                      return Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 4,
                              height: 36,
                              decoration: BoxDecoration(
                                color: c,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text('#${i + 1}',
                                style: tt.bodyMedium
                                    ?.copyWith(color: cs.onSurfaceVariant)),
                            const Spacer(),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                Text(
                                  '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} BPM',
                                  style: tt.bodyLarge?.copyWith(
                                    color: c,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${ms >= 0 ? '+' : ''}${ms}ms',
                                  style: tt.bodySmall?.copyWith(color: c),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _beatSubscription?.cancel();
    _needleController.dispose();
    _flashController?.dispose();
    _rippleDriverController.dispose();
    _patternProgressController.dispose();
    _bpmTextController.dispose();
    _deviationState.dispose();
    _patternTimer?.cancel();
    _patternIndexNotifier.dispose();
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
                        'Rhythm Checker',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      tooltip: 'リズムパターン',
                      onPressed: _isPlaying ? null : () => _showPatternSheet(context),
                    ),
                    IconButton(
                      icon: Icon(switch (_visualMode) {
                        VisualMode.metronome => Icons.straighten,
                        VisualMode.wave      => Icons.blur_on,
                        VisualMode.flash     => Icons.flash_on,
                      }),
                      tooltip: switch (_visualMode) {
                        VisualMode.metronome => 'メトロノーム',
                        VisualMode.wave      => '波',
                        VisualMode.flash     => '点滅',
                      },
                      onPressed: () {
                        setState(() {
                          _visualMode = VisualMode.values[
                            (_visualMode.index + 1) % VisualMode.values.length
                          ];
                          _rippleStartTimes.clear();
                          _flashController?.stop(canceled: true);
                          _flashController?.value = 0;
                        });
                      },
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
                if (_selectedPattern.id != 'quarter')
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: AnimatedBuilder(
                      animation: Listenable.merge(<Listenable>[
                        _patternProgressController,
                        _patternIndexNotifier,
                      ]),
                      builder: (BuildContext context, Widget? _) {
                        return _PatternVisualizer(
                          intervals: _selectedPattern.intervals,
                          currentIndex: _patternIndexNotifier.value,
                          progress: _patternProgressController.value,
                          isPlaying: _isPlaying,
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: <Widget>[
                      Listener(
                        onPointerDown: (_) {
                          setState(() => _isTapping = true);
                          _onCircleTap();
                        },
                        onPointerUp: (_) => setState(() => _isTapping = false),
                        onPointerCancel: (_) => setState(() => _isTapping = false),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 168,
                          height: 168,
                          color: Colors.transparent,
                          child: Center(
                            child: AnimatedScale(
                              scale: _isTapping ? 0.88 : 1.0,
                              duration: const Duration(milliseconds: 80),
                              curve: Curves.easeOut,
                              child: AnimatedBuilder(
                                animation: _flashController ?? _needleController,
                                builder: (BuildContext context, Widget? _) {
                                  final ColorScheme cs = Theme.of(context).colorScheme;
                                  final Color color = Color.lerp(
                                    cs.primaryContainer,
                                    cs.primary,
                                    _flashController?.value ?? 0.0,
                                  )!;
                                  final Color iconColor = Color.lerp(
                                    cs.onPrimaryContainer,
                                    cs.onPrimary,
                                    _flashController?.value ?? 0.0,
                                  )!.withOpacity(0.55);
                                  return Container(
                                    width: 120,
                                    height: 120,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      boxShadow: <BoxShadow>[
                                        BoxShadow(
                                          color: cs.primary.withOpacity(0.40),
                                          blurRadius: _isTapping ? 4 : 18,
                                          spreadRadius: _isTapping ? 0 : 2,
                                          offset: Offset(0, _isTapping ? 1 : 5),
                                        ),
                                      ],
                                    ),
                                    child: (_isPlaying && _syncTime == null)
                                        ? Transform.translate(
                                            offset: const Offset(0, 22),
                                            child: Icon(
                                              Icons.pan_tool_alt,
                                              color: iconColor,
                                              size: 38,
                                            ),
                                          )
                                        : null,
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_visualMode == VisualMode.wave)
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
                      if (_visualMode == VisualMode.metronome)
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
                      ({bool isWarmingUp, bool isTooFast, double? ratio, double? bpm, int? deviationMs}) state, _) {
                    if (!_isPlaying) return const SizedBox.shrink();
                    if (state.isWarmingUp) {
                      return Text(
                        'リズム測定中...',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Colors.grey,
                            ),
                      );
                    }
                    if (state.isTooFast) {
                      return Text(
                        'Too fast!',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.orange,
                        ),
                      );
                    }
                    final double? r = state.ratio;
                    final double? d = state.bpm;
                    final int? ms = state.deviationMs;
                    if (r == null || d == null || ms == null) return const SizedBox.shrink();
                    final Color c = r.abs() < 0.05
                        ? Colors.green
                        : r.abs() < 0.10
                            ? Colors.orange
                            : Colors.red;
                    return Column(
                      children: <Widget>[
                        Text(
                          '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} BPM',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: c),
                        ),
                        Text(
                          '${ms >= 0 ? '+' : ''}${ms}ms',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c),
                        ),
                      ],
                    );
                  },
                ),
                if (!_isPlaying && _tapDeviationLog.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _showTapLogDialog(context),
                    icon: const Icon(Icons.bar_chart_rounded),
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

class _PatternCard extends StatelessWidget {
  const _PatternCard({
    required this.pattern,
    required this.isSelected,
    required this.onTap,
  });

  final RhythmPattern pattern;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        height: 56,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isSelected ? cs.primaryContainer : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? cs.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: pattern.intervals.map((double interval) {
            return Expanded(
              flex: (interval * 100).round(),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _PatternVisualizer extends StatelessWidget {
  const _PatternVisualizer({
    required this.intervals,
    required this.currentIndex,
    required this.progress,
    required this.isPlaying,
  });

  final List<double> intervals;
  final int currentIndex;
  final double progress;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 32,
      child: Row(
        children: List<Widget>.generate(intervals.length, (int i) {
          final bool isPast = isPlaying && i < currentIndex;
          final bool isCurrent = isPlaying && i == currentIndex;
          return Expanded(
            flex: (intervals[i] * 100).round(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: <Widget>[
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    color: isPast
                        ? cs.primary.withOpacity(0.35)
                        : cs.surfaceContainerHighest,
                  ),
                  if (isCurrent)
                    FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        color: cs.primary,
                      ),
                    ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextTheme tt = Theme.of(context).textTheme;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          Text(value, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.count,
    required this.pct,
    required this.color,
  });

  final String label;
  final int count;
  final String pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: <Widget>[
            Text(count.toString(),
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color)),
            Text(pct,
                style: TextStyle(fontSize: 12, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: Colors.grey.shade600)),
          ],
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
