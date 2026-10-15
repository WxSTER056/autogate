import 'dart:async';
import 'package:flutter/material.dart';
import '../services/firebase_service.dart';
import '../services/gate_command.dart';
import '../services/speech_service.dart';
import '../widgets/pulse_mic_button.dart';
import '../widgets/settings_dialog.dart';

/// Command strings emitted by the speech service.
const String kCommandOpenDoor = 'OPEN_DOOR';
const String kCommandCloseDoor = 'CLOSE_DOOR';

/// Maps a recognised voice command to the gate action it performs.
GateAction actionForCommand(String command) {
  switch (command) {
    case kCommandOpenDoor:
    case kCommandCloseDoor:
    default:
      return GateAction.toggle;
  }
}

/// Display text for a recognised voice command.
String labelForCommand(String command) {
  switch (command) {
    case kCommandOpenDoor:
      return "OPEN THE DOOR";
    case kCommandCloseDoor:
      return "CLOSE THE DOOR";
    default:
      return command;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final GateService _gateService = GateService();
  final SpeechService _speechService = SpeechService();

  late AnimationController _gateAnimController;
  bool _isAutoListenEnabled = true;
  String? _lastDetectedCommandDisplay;
  Timer? _commandDisplayTimer;
  bool _isPressingTrigger = false;

  @override
  void initState() {
    super.initState();

    _gateAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    // Initialize Firebase and Speech after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
    });
  }

  Future<void> _initServices() async {
    // 1. Initialize Firebase
    await _gateService.initialize();

    // 2. Setup speech callback
    _speechService.onDoorCommandDetected = (command) {
      _handleVoiceCommand(command);
    };

    // 3. Auto-start listening on app launch
    if (_isAutoListenEnabled) {
      await _speechService.initSpeech();
      await _speechService.startListening();
    }
  }

  void _handleVoiceCommand(String command) {
    final action = actionForCommand(command);
    setState(() {
      _lastDetectedCommandDisplay = labelForCommand(command);
    });

    _commandDisplayTimer?.cancel();
    _commandDisplayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _lastDetectedCommandDisplay = null;
        });
      }
    });

    // Send trigger signal to Firebase
    _sendGateTrigger("Voice: ${action.label}", action: action);
  }

  Future<void> _sendGateTrigger(
    String source, {
    GateAction action = GateAction.toggle,
  }) async {
    _gateAnimController.forward(from: 0.0);
    final success =
        await _gateService.sendTriggerSignal(source: source, action: action);
    if (!mounted) return;

    // Replace any queued snackbar instead of stacking them.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text("RF Signal Sent ($source)!"),
          ],
        ),
        backgroundColor: const Color(0xFF059669),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Failed to send signal. Please check Firebase settings."),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _toggleListening() {
    if (_speechService.isListening.value) {
      _speechService.stopListening();
    } else {
      _speechService.startListening();
    }
  }

  void _openSettings() {
    showDialog(
      context: context,
      builder: (context) => const SettingsDialog(),
    );
  }

  void _showLogsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return ValueListenableBuilder<List<String>>(
          valueListenable: _gateService.logs,
          builder: (context, logs, _) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Activity & Diagnostics Log",
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(context),
                      )
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  Expanded(
                    child: logs.isEmpty
                        ? const Center(
                            child: Text(
                              "No logs recorded yet.",
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        : ListView.builder(
                            itemCount: logs.length,
                            itemBuilder: (context, idx) {
                              final log = logs[idx];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4.0),
                                child: Text(
                                  log,
                                  style: const TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _gateAnimController.dispose();
    _commandDisplayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.sensor_door, color: Color(0xFF38BDF8), size: 22),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "AUTOGATE CONTROLLER",
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: Colors.white,
                  ),
                ),
                Text(
                  "ESP32 • CC1101 330MHz",
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long, color: Colors.white70),
            tooltip: "Diagnostics Log",
            onPressed: _showLogsModal,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: "Firebase Settings",
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top Cloud & ESP32 Status Header
              _buildConnectionStatusBar(),

              const SizedBox(height: 18),

              // Voice Command Banner if triggered
              if (_lastDetectedCommandDisplay != null) ...[
                _buildVoiceTriggeredBanner(),
                const SizedBox(height: 16),
              ],

              // Voice Recognition Central Card
              _buildVoiceControlCard(),

              const SizedBox(height: 20),

              // Gate Status & Visualizer Card
              _buildGateVisualizerCard(),

              const SizedBox(height: 24),

              // Primary Manual Control Buttons
              _buildManualControls(),

              const SizedBox(height: 20),

              // Voice Commands Helper Cheat Sheet
              _buildVoiceHelpChips(),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131D31),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Firebase Cloud Status
          ValueListenableBuilder<bool>(
            valueListenable: _gateService.isConnected,
            builder: (context, connected, _) {
              final configured = _gateService.isConfigured.value;
              final color = !configured
                  ? const Color(0xFFF87171)
                  : (connected ? const Color(0xFF10B981) : const Color(0xFFF59E0B));
              final label = !configured
                  ? "Cloud: Not configured"
                  : (connected ? "Cloud: Online" : "Cloud: Connecting...");

              return Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: !configured
                          ? const Color(0xFFFCA5A5)
                          : (connected
                              ? const Color(0xFF34D399)
                              : const Color(0xFFFBBF24)),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            },
          ),

          // ESP32 Status
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_gateService.secureTriggerMode) ...[
                  _buildBadge(
                    label: "SIGNED",
                    color: const Color(0xFF10B981),
                    tooltip: "指令带 HMAC 签名，固件会校验",
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _gateService.doorStatus,
                    builder: (context, status, _) {
                      Color statusColor = const Color(0xFF94A3B8);
                      if (status == "action_completed") statusColor = const Color(0xFF10B981);
                      if (status == "triggering") statusColor = const Color(0xFF38BDF8);

                      return _buildBadge(
                        label: "ESP32: ${status.toUpperCase()}",
                        color: statusColor,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge({
    required String label,
    required Color color,
    String? tooltip,
  }) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip, child: badge);
  }

  Widget _buildVoiceTriggeredBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF047857), Color(0xFF10B981)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF10B981).withValues(alpha: 0.4),
            blurRadius: 12,
            spreadRadius: 2,
          )
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.record_voice_over, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "VOICE COMMAND ACTIVATED!",
                  style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                Text(
                  _lastDetectedCommandDisplay ?? "",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.sensors, color: Colors.white, size: 24),
        ],
      ),
    );
  }

  Widget _buildVoiceControlCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFF131D31),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        children: [
          // Header of Voice Card with Toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.graphic_eq, color: Color(0xFF38BDF8), size: 20),
                  SizedBox(width: 8),
                  Text(
                    "VOICE ASSISTANT",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text("Auto-listen", style: TextStyle(color: Colors.white60, fontSize: 12)),
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _isAutoListenEnabled,
                      activeTrackColor: const Color(0xFF38BDF8),
                      activeThumbColor: Colors.white,
                      onChanged: (val) {
                        setState(() {
                          _isAutoListenEnabled = val;
                          _speechService.continuousListening = val;
                        });
                        if (val) {
                          _speechService.startListening();
                        } else {
                          _speechService.stopListening();
                        }
                      },
                    ),
                  ),
                ],
              )
            ],
          ),

          const SizedBox(height: 20),

          // Central Pulse Mic Widget
          ValueListenableBuilder<bool>(
            valueListenable: _speechService.isListening,
            builder: (context, listening, _) {
              return ValueListenableBuilder<double>(
                valueListenable: _speechService.soundLevel,
                builder: (context, level, _) {
                  return PulseMicButton(
                    isListening: listening,
                    soundLevel: level,
                    onTap: _toggleListening,
                  );
                },
              );
            },
          ),

          const SizedBox(height: 20),

          // Status & Speech Live Output
          ValueListenableBuilder<bool>(
            valueListenable: _speechService.isListening,
            builder: (context, listening, _) {
              return ValueListenableBuilder<String>(
                valueListenable: _speechService.wordsSpoken,
                builder: (context, words, _) {
                  return Column(
                    children: [
                      Text(
                        listening ? "Listening for speech..." : "Tap mic to activate voice",
                        style: TextStyle(
                          color: listening ? const Color(0xFF38BDF8) : Colors.white60,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF1E293B)),
                        ),
                        child: Text(
                          words.isNotEmpty ? "\"$words\"" : "Say: \"Open the door\" or \"Close the door\"",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: words.isNotEmpty ? Colors.white : Colors.white38,
                            fontSize: 14,
                            fontStyle: words.isNotEmpty ? FontStyle.normal : FontStyle.italic,
                            fontWeight: words.isNotEmpty ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildGateVisualizerCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131D31),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "GATE TRANSMISSION",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: _gateService.lastTriggerTime,
                builder: (context, time, _) {
                  return Text(
                    time != null ? "Last triggered: $time" : "Awaiting first trigger",
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Gate RF Transmission animation visual
          ValueListenableBuilder<bool>(
            valueListenable: _gateService.isTriggerActive,
            builder: (context, isTriggerActive, _) {
              return Container(
                height: 70,
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1120),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isTriggerActive ? const Color(0xFF38BDF8) : const Color(0xFF1E293B),
                  ),
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.settings_remote,
                        color: isTriggerActive ? const Color(0xFF38BDF8) : Colors.white54,
                        size: 32,
                      ),
                      const SizedBox(width: 14),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isTriggerActive ? "Transmitting RF: 330MHz (Code: 21487477)" : "RF Transmitter Standby",
                            style: TextStyle(
                              color: isTriggerActive ? const Color(0xFF38BDF8) : Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            isTriggerActive ? "Sending 10 repeats to CC1101..." : "Protocol 5 • Pulse 580μs • 25-bit",
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildManualControls() {
    return Row(
      children: [
        Expanded(
          child: _buildTriggerButton(
            label: "一键开关门",
            sublabel: "TRIGGER",
            icon: Icons.power_settings_new,
            colors: const [Color(0xFF0284C7), Color(0xFF2563EB)],
            onTap: () => _sendGateTrigger("Manual Button"),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _buildTriggerButton(
            label: "半开门",
            sublabel: "HALF OPEN",
            icon: Icons.door_sliding,
            colors: const [Color(0xFF7C3AED), Color(0xFFA855F7)],
            onTap: () => _sendGateTrigger("Half Open Button",
                action: GateAction.halfOpen),
          ),
        ),
      ],
    );
  }

  Widget _buildTriggerButton({
    required String label,
    required String sublabel,
    required IconData icon,
    required List<Color> colors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressingTrigger = true),
      onTapUp: (_) => setState(() => _isPressingTrigger = false),
      onTapCancel: () => setState(() => _isPressingTrigger = false),
      onTap: onTap,
      child: AnimatedScale(
        scale: _isPressingTrigger ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          height: 96,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: colors.last.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 30),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              Text(
                sublabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceHelpChips() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Color(0xFFFBBF24), size: 18),
              SizedBox(width: 8),
              Text(
                "Supported Voice Commands",
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChip("🗣️ \"Open the door\""),
              _buildChip("🗣️ \"Close the door\""),
              _buildChip("🗣️ \"Open gate\""),
              _buildChip("🗣️ \"Close gate\""),
              _buildChip("🗣️ \"开门\""),
              _buildChip("🗣️ \"关门\""),
              _buildChip("🗣️ \"开闸\" / \"关闸\""),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            "需要同时包含“动作词 + 门/闸”，因此 “open the app”、“close the browser” "
            "之类的闲聊不会误触发。",
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
      ),
    );
  }
}
