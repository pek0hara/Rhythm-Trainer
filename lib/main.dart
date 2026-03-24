import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

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
    with SingleTickerProviderStateMixin {
  int _bpm = 120;
  bool _isPlaying = false;
  bool _isTicking = false;

  Timer? _timer;
  late final AudioPlayer _player;
  late final Uint8List _clickSound;
  DeviceFileSource? _clickSource;
  late final AnimationController _needleController;
  late final Animation<double> _needleAngle;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer(playerId: 'metronome-player');
    _needleController = AnimationController(
      vsync: this,
      duration: _beatDuration,
    );
    _needleAngle = Tween<double>(
      begin: -math.pi / 4,
      end: math.pi / 4,
    ).animate(
      CurvedAnimation(parent: _needleController, curve: Curves.easeInOut),
    );
    _clickSound = _buildToneWav(
      frequencyHz: 1000,
      durationMs: 40,
      volume: 0.5,
    );
    _initClickSource();
  }

  Future<void> _initClickSource() async {
    final Directory tmpDir = await getTemporaryDirectory();
    final File wavFile = File('${tmpDir.path}/click.wav');
    await wavFile.writeAsBytes(_clickSound);
    _clickSource = DeviceFileSource(wavFile.path);
  }

  Duration get _beatDuration => Duration(milliseconds: (60000 / _bpm).round());

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

  Future<void> _tick() async {
    setState(() {
      _isTicking = true;
    });

    if (_clickSource == null) return;
    await _player.stop();
    await _player.play(_clickSource!);

    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _isTicking = false;
      });
    });
  }

  void _start() {
    _timer?.cancel();
    final Duration beatDuration = _beatDuration;

    setState(() {
      _isPlaying = true;
    });

    _needleController
      ..duration = beatDuration
      ..repeat(reverse: true);

    unawaited(_tick());
    _timer = Timer.periodic(beatDuration, (_) {
      unawaited(_tick());
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _isPlaying = false;
      _isTicking = false;
    });
    _needleController
      ..stop()
      ..reset();
  }

  void _togglePlay() {
    if (_isPlaying) {
      _stop();
    } else {
      _start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _needleController.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Metronome')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              const Spacer(),
              Text(
                '$_bpm BPM',
                style: Theme.of(context).textTheme.headlineMedium,
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
                        });
                      },
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 220,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: _isTicking
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                    ),
                    AnimatedBuilder(
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
                        child: Container(
                          width: 8,
                          height: 120,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _togglePlay,
                icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow),
                label: Text(_isPlaying ? '停止' : '再生'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
