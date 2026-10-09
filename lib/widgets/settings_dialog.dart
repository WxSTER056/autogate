import 'package:flutter/material.dart';
import '../services/firebase_service.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _projectIdCtrl;
  late final TextEditingController _dbUrlCtrl;
  late final TextEditingController _apiKeyCtrl;

  @override
  void initState() {
    super.initState();
    final service = GateService();
    _projectIdCtrl = TextEditingController(text: service.projectId);
    _dbUrlCtrl = TextEditingController(text: service.databaseUrl);
    _apiKeyCtrl = TextEditingController(text: service.apiKey);
  }

  @override
  void dispose() {
    _projectIdCtrl.dispose();
    _dbUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _saveSettings() async {
    final service = GateService();
    await service.initialize(
      customProjectId: _projectIdCtrl.text.trim(),
      customDbUrl: _dbUrlCtrl.text.trim(),
      customApiKey: _apiKeyCtrl.text.trim(),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Settings saved & Firebase re-initialized!"),
          backgroundColor: Color(0xFF10B981),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E222D),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.settings, color: Color(0xFF38BDF8), size: 26),
                  const SizedBox(width: 12),
                  const Text(
                    "Firebase Configuration",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white60),
                    onPressed: () => Navigator.of(context).pop(),
                  )
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                "Match these with your Firebase Console and ESP32 code settings:",
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),

              // Project ID
              _buildField(
                label: "Firebase Project ID",
                controller: _projectIdCtrl,
                hint: "e.g. wong-autogate",
                helperText: "From your Firebase URL (wong-autogate)",
              ),
              const SizedBox(height: 16),

              // RTDB URL
              _buildField(
                label: "Realtime Database URL",
                controller: _dbUrlCtrl,
                hint: "https://wong-autogate-default-rtdb.firebaseio.com",
                helperText: "Copy from Firebase Console > Realtime Database",
              ),
              const SizedBox(height: 16),

              // API Key
              _buildField(
                label: "Web API Key",
                controller: _apiKeyCtrl,
                hint: "AIzaSy...",
                helperText: "Found in Firebase Console > Project Settings > General",
              ),
              const SizedBox(height: 24),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text("Cancel", style: TextStyle(color: Colors.white60)),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: const Color(0xFF0F172A),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _saveSettings,
                    child: const Text("Apply & Connect", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required String helperText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
            helperText: helperText,
            helperStyle: const TextStyle(color: Colors.white38, fontSize: 11),
            filled: true,
            fillColor: const Color(0xFF0F172A),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF334155)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
