import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  RhythmPattern get _selectedPattern => _patterns[_selectedPatternIndex];

  void _registerTap() {
    SystemSound.play(SystemSoundType.click);

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
        SystemSound.play(
          isAccent ? SystemSoundType.click : SystemSoundType.alert,
        );
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
