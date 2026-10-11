/// What the gate should physically do when a trigger is accepted.
///
/// The wire value is what travels to the ESP32 in the trigger payload; the
/// firmware decides how many RF pulses each one produces.
enum GateAction {
  /// A single pulse, which opens the gate if it is closed and closes it if
  /// it is open. This is the normal button and "open"/"close the door" voice
  /// behaviour.
  toggle('toggle', '一键开关门'),

  /// Two pulses three seconds apart, which leaves the gate in the half-open
  /// position.
  halfOpen('half_open', '半开门');

  const GateAction(this.wire, this.label);

  /// Value written into the trigger payload's `action` field.
  final String wire;

  /// Human readable name shown in the UI.
  final String label;

  /// How many RF pulses the firmware should send.
  int get pulseCount => this == GateAction.halfOpen ? 2 : 1;

  /// Gap between pulses, only meaningful when [pulseCount] is greater than one.
  static const Duration pulseGap = Duration(seconds: 3);

  /// Parses a value received from the firmware or a stored payload.
  /// Anything unrecognised falls back to [toggle] so older payloads keep working.
  static GateAction fromWire(String? value) {
    for (final action in GateAction.values) {
      if (action.wire == value) return action;
    }
    return GateAction.toggle;
  }
}
