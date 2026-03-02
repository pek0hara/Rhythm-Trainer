import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const RhythmTrainerApp());
}

class RhythmTrainerApp extends StatelessWidget {
  const RhythmTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rhythm Trainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const RhythmTrainerPage(),
    );
  }
}

class RhythmPattern {
  const RhythmPattern({
    required this.name,
    required this.steps,
    required this.accentIndices,
  });

  final String name;
  final int steps;
  final Set<int> accentIndices;

  bool isAccent(int index) => accentIndices.contains(index);
}

class RhythmTrainerPage extends StatefulWidget {
  const RhythmTrainerPage({super.key});

  @override
  State<RhythmTrainerPage> createState() => _RhythmTrainerPageState();
}

class _RhythmTrainerPageState extends State<RhythmTrainerPage> {
  final List<DateTime> _tapTimes = <DateTime>[];
  final List<double> _tapBpms = <double>[];

  static const List<RhythmPattern> _patterns = <RhythmPattern>[
    RhythmPattern(name: '4分音符 (4拍子)', steps: 4, accentIndices: <int>{0}),
    RhythmPattern(name: '8ビート', steps: 8, accentIndices: <int>{0, 4}),
    RhythmPattern(name: '3連符', steps: 3, accentIndices: <int>{0}),
    RhythmPattern(name: '16ビート', steps: 16, accentIndices: <int>{0, 4, 8, 12}),
    RhythmPattern(name: '3-3-2 clave', steps: 8, accentIndices: <int>{0, 3, 6}),
  ];

  int _selectedPatternIndex = 0;
  int _configuredBpm = 120;
  Timer? _metronomeTimer;
  bool _isPlaying = false;
  int _currentStep = -1;

  late final AudioPlayer _tapPlayer;
  late final AudioPlayer _accentPlayer;
  late final AudioPlayer _beatPlayer;

  late final Uint8List _tapSoundBytes;
  late final Uint8List _accentSoundBytes;
  late final Uint8List _beatSoundBytes;

  RhythmPattern get _selectedPattern => _patterns[_selectedPatternIndex];

  @override
  void initState() {
    super.initState();

    _tapPlayer = AudioPlayer(playerId: 'tap-player');
    _accentPlayer = AudioPlayer(playerId: 'accent-player');
    _beatPlayer = AudioPlayer(playerId: 'beat-player');

    _tapSoundBytes = _buildToneWav(
      frequencyHz: 1000,
      durationMs: 50,
      volume: 0.5,
    );
    _accentSoundBytes = _buildToneWav(
      frequencyHz: 1200,
      durationMs: 80,
      volume: 0.55,
    );
    _beatSoundBytes = _buildToneWav(
      frequencyHz: 800,
      durationMs: 60,
      volume: 0.45,
    );
  }

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
    bytes.setUint32(16, 16, Endian.little); // PCM chunk size
    bytes.setUint16(20, 1, Endian.little); // PCM format
    bytes.setUint16(22, 1, Endian.little); // mono channel
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    bytes.setUint16(32, 2, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
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

  Future<void> _playTapSound() async {
    await _tapPlayer.stop();
    await _tapPlayer.play(BytesSource(_tapSoundBytes));
  }

  Future<void> _playSampleSound({required bool isAccent}) async {
    final AudioPlayer player = isAccent ? _accentPlayer : _beatPlayer;
    final Uint8List soundBytes = isAccent ? _accentSoundBytes : _beatSoundBytes;
    await player.stop();
    await player.play(BytesSource(soundBytes));
  }

  void _registerTap() {
    unawaited(_playTapSound());

    final DateTime now = DateTime.now();

    if (_tapTimes.isNotEmpty) {
      final int elapsedMs = now.difference(_tapTimes.last).inMilliseconds;
      if (elapsedMs > 0) {
        final double bpm = 60000 / elapsedMs;
        _tapBpms.add(bpm);
      }
    }

    setState(() {
      _tapTimes.add(now);
    });
  }

  void _reset() {
    _stopPattern();
    setState(() {
      _tapTimes.clear();
      _tapBpms.clear();
      _configuredBpm = 120;
      _selectedPatternIndex = 0;
      _currentStep = -1;
    });
  }

  void _startPattern() {
    _metronomeTimer?.cancel();

    final int intervalMs = (60000 / _configuredBpm).round();
    setState(() {
      _isPlaying = true;
      _currentStep = -1;
    });

    _metronomeTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (Timer timer) {
        setState(() {
          _currentStep = (_currentStep + 1) % _selectedPattern.steps;
        });

        final bool isAccent = _selectedPattern.isAccent(_currentStep);
        unawaited(_playSampleSound(isAccent: isAccent));
      },
    );
  }

  void _stopPattern() {
    _metronomeTimer?.cancel();
    _metronomeTimer = null;

    if (mounted) {
      setState(() {
        _isPlaying = false;
        _currentStep = -1;
      });
    }
  }

  void _togglePlayback() {
    if (_isPlaying) {
      _stopPattern();
    } else {
      _startPattern();
    }
  }

  double get _averageBpm {
    if (_tapBpms.isEmpty) {
      return 0;
    }
    final double sum = _tapBpms.reduce((double a, double b) => a + b);
    return sum / _tapBpms.length;
  }

  double get _deviationStdDev {
    if (_tapBpms.length < 2) {
      return 0;
    }

    final double mean = _averageBpm;
    final double variance =
        _tapBpms
            .map((double bpm) => (bpm - mean) * (bpm - mean))
            .reduce((double a, double b) => a + b) /
        _tapBpms.length;

    return math.sqrt(variance);
  }

  double get _stabilityScore {
    if (_tapBpms.isEmpty) {
      return 0;
    }

    return (100 - (_deviationStdDev * 2)).clamp(0, 100).toDouble();
  }

  @override
  void dispose() {
    _metronomeTimer?.cancel();
    _tapPlayer.dispose();
    _accentPlayer.dispose();
    _beatPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double avg = _averageBpm;
    final double stdDev = _deviationStdDev;
    final double score = _stabilityScore;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rhythm Trainer'),
        actions: <Widget>[
          IconButton(
            onPressed: _reset,
            icon: const Icon(Icons.refresh),
            tooltip: 'リセット',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      DropdownButtonFormField<int>(
                        initialValue: _selectedPatternIndex,
                        decoration: const InputDecoration(
                          labelText: 'リズムパターン',
                          border: OutlineInputBorder(),
                        ),
                        items: List<DropdownMenuItem<int>>.generate(
                          _patterns.length,
                          (int index) => DropdownMenuItem<int>(
                            value: index,
                            child: Text(_patterns[index].name),
                          ),
                        ),
                        onChanged: _isPlaying
                            ? null
                            : (int? value) {
                                if (value == null) {
                                  return;
                                }
                                setState(() {
                                  _selectedPatternIndex = value;
                                  _currentStep = -1;
                                });
                              },
                      ),
                      const SizedBox(height: 12),
                      Text('BPM: $_configuredBpm'),
                      Slider(
                        value: _configuredBpm.toDouble(),
                        min: 40,
                        max: 240,
                        divisions: 200,
                        label: _configuredBpm.toString(),
                        onChanged: _isPlaying
                            ? null
                            : (double value) {
                                setState(() {
                                  _configuredBpm = value.round();
                                });
                              },
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _togglePlayback,
                        icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                        label: Text(_isPlaying ? '停止' : '再生'),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List<Widget>.generate(
                          _selectedPattern.steps,
                          (int index) {
                            final bool active = index == _currentStep;
                            final bool accent = _selectedPattern.isAccent(index);

                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: active
                                    ? (accent ? Colors.deepPurple : Colors.teal)
                                    : (accent
                                        ? Colors.deepPurple.withOpacity(0.2)
                                        : Colors.grey.withOpacity(0.2)),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: active ? Colors.white : Colors.black87,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      _ScoreItem(
                        label: '平均BPM',
                        value: avg.toStringAsFixed(1),
                      ),
                      _ScoreItem(
                        label: '標準偏差',
                        value: stdDev.toStringAsFixed(2),
                      ),
                      _ScoreItem(
                        label: 'スコア',
                        value: '${score.toStringAsFixed(1)} / 100',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: FilledButton.tonal(
                    onPressed: _registerTap,
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(56),
                    ),
                    child: const Text(
                      'TAP',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '各タップBPM',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _tapBpms.isEmpty
                    ? const Center(child: Text('2回以上タップすると表示されます'))
                    : ListView.separated(
                        itemCount: _tapBpms.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (BuildContext context, int index) {
                          final double bpm = _tapBpms[index];
                          final double diff = bpm - avg;
                          final String sign = diff >= 0 ? '+' : '-';

                          return ListTile(
                            dense: true,
                            leading: Text('#${index + 1}'),
                            title: Text('${bpm.toStringAsFixed(1)} BPM'),
                            trailing: Text(
                              '$sign${diff.abs().toStringAsFixed(1)}',
                              style: TextStyle(
                                color: diff.abs() < stdDev
                                    ? Colors.green
                                    : Colors.orange,
                              ),
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
  }
}

class _ScoreItem extends StatelessWidget {
  const _ScoreItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
