/// What the gate should physically do when a trigger is accepted.
///
/// The wire value is what travels to the ESP32 in the trigger payload; the
/// firmware always turns one trigger into one RF pulse.
enum GateAction {
  /// A single pulse, which opens the gate if it is closed and closes it if
  /// it is open. Used by the main button and by every voice command.
  toggle('toggle', '一键开关门'),

  /// Identical to [toggle], except the app repeats the trigger after
  /// [pulseGap] so the gate ends up half open.
  halfOpen('half_open', '半开门');

  const GateAction(this.wire, this.label);

  /// Value written into the trigger payload's `action` field.
  final String wire;

  /// Human readable name shown in the UI.
  final String label;

  /// How many triggers the app sends.
  int get pulseCount => this == GateAction.halfOpen ? 2 : 1;

  /// Gap between the two triggers for [halfOpen].
  static const Duration pulseGap = Duration(seconds: 5);

  /// Parses a value received from the firmware or a stored payload.
  /// Anything unrecognised falls back to [toggle] so older payloads keep working.
  static GateAction fromWire(String? value) {
    for (final action in GateAction.values) {
      if (action.wire == value) return action;
    }
    return GateAction.toggle;
  }
}
