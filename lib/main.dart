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

class RhythmTrainerPage extends StatefulWidget {
  const RhythmTrainerPage({super.key});

  @override
  State<RhythmTrainerPage> createState() => _RhythmTrainerPageState();
}

class _RhythmTrainerPageState extends State<RhythmTrainerPage> {
  final List<DateTime> _tapTimes = <DateTime>[];
  final List<double> _tapBpms = <double>[];

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
    setState(() {
      _tapTimes.clear();
      _tapBpms.clear();
    });
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
                      Text(
                        '平均BPM: ${avg.toStringAsFixed(1)}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('標準偏差: ${stdDev.toStringAsFixed(2)}'),
                      const SizedBox(height: 8),
                      Text(
                        'スコア: ${score.toStringAsFixed(1)} / 100',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
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
