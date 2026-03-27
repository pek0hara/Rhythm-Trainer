package com.example.rhythm_trainer

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL = "com.rhythmtrainer.metronome/control"
    private val EVENT_CHANNEL = "com.rhythmtrainer.metronome/beats"

    private val sampleRate = 44100
    private var clickTrack: AudioTrack? = null

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var isRunning = false
    @Volatile private var isMuted = false
    private var metronomeThread: Thread? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val wavBytes = call.arguments as? ByteArray
                        if (wavBytes != null) {
                            Thread {
                                prepareTrack(wavBytes)
                                mainHandler.post { result.success(null) }
                            }.start()
                        } else {
                            result.success(null)
                        }
                    }
                    "start" -> {
                        val bpm = call.arguments as? Double
                        if (bpm != null) startMetronome(bpm)
                        result.success(null)
                    }
                    "stop" -> {
                        stopMetronome()
                        result.success(null)
                    }
                    "setMuted" -> {
                        isMuted = call.arguments as? Boolean ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    // WAVヘッダ(44バイト)をスキップしてAudioTrackを一度だけ生成
    private fun prepareTrack(wav: ByteArray) {
        val dataOffset = 44
        val remaining = wav.size - dataOffset
        val samples = ShortArray(remaining / 2)
        ByteBuffer.wrap(wav, dataOffset, remaining)
            .order(ByteOrder.LITTLE_ENDIAN)
            .asShortBuffer()
            .get(samples)

        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuf, samples.size * 2))
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        track.write(samples, 0, samples.size)
        clickTrack?.release()
        clickTrack = track
    }

    private fun startMetronome(bpm: Double) {
        stopMetronome()
        isRunning = true
        val intervalNs = (60_000_000_000.0 / bpm).toLong()

        metronomeThread = Thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)

            var nextBeatNs = SystemClock.elapsedRealtimeNanos()

            while (isRunning) {
                val nowNs = SystemClock.elapsedRealtimeNanos()
                val sleepNs = nextBeatNs - nowNs
                if (sleepNs > 0) {
                    val sleepMs = sleepNs / 1_000_000
                    val sleepNsRem = (sleepNs % 1_000_000).toInt()
                    try { Thread.sleep(sleepMs, sleepNsRem) } catch (_: InterruptedException) { break }
                }
                if (!isRunning) break

                playClick()
                mainHandler.post { eventSink?.success(null) }
                nextBeatNs += intervalNs
            }
        }.also { it.start() }
    }

    private fun stopMetronome() {
        isRunning = false
        metronomeThread?.interrupt()
        metronomeThread = null
    }

    private fun playClick() {
        if (isMuted) return
        val track = clickTrack ?: return
        track.stop()
        track.reloadStaticData()
        track.play()
    }

    override fun onDestroy() {
        stopMetronome()
        clickTrack?.release()
        clickTrack = null
        super.onDestroy()
    }
}
