import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bantay_app/alerts/alert_gateway.dart';
import 'package:bantay_app/alerts/contact_store.dart';
import 'package:bantay_app/sensor_payload.dart';
import 'package:bantay_app/sensors/sensor_bridge.dart';
import 'package:bantay_app/alerts/native_incident_gateway.dart';
import 'package:bantay_llm/bantay_llm.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const _blue = Color(0xFF013791);
const _green = Color(0xFF185C43);
const _red = Color(0xFFC52222);
const _canvas = Color(0xFFF5F7FA);
const _paleBlue = Color(0xFFE2EFFD);

enum _Page { loading, setup, calibrating, guardian, incident, result }

class ProductApp extends StatelessWidget {
  const ProductApp({
    super.key,
    this.contactStore,
    this.testSetupOnly = false,
  });
  final ContactStore? contactStore;
  final bool testSetupOnly;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bantay',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: _canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: _blue),
      appBarTheme: const AppBarTheme(
        backgroundColor: _canvas,
        foregroundColor: Color(0xFF101627),
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _blue,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xFFE5E9EF)),
        ),
      ),
    ),
    home: _ProductHome(
      contactStore: contactStore,
      testSetupOnly: testSetupOnly,
    ),
  );
}

class _ProductHome extends StatefulWidget {
  const _ProductHome({
    this.contactStore,
    required this.testSetupOnly,
  });
  final ContactStore? contactStore;
  final bool testSetupOnly;
  @override
  State<_ProductHome> createState() => _ProductHomeState();
}

class _ProductHomeState extends State<_ProductHome> {
  final SensorBridge _sensors = SensorBridge();
  final NativeIncidentGateway _gateway = NativeIncidentGateway();
  late final ContactStore _contacts = widget.contactStore ?? ContactStore();
  final BantayPath2 _path2 = BantayPath2();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _number = TextEditingController();
  StreamSubscription<AccelBatch>? _batchSub;
  StreamSubscription<SensorStatus>? _stateSub;
  StreamSubscription<SmsSubmission>? _smsStatusSub;
  StreamSubscription<NativeIncidentSnapshot>? _nativeSub;
  StreamSubscription<DetectorDiagnostics>? _diagnosticSub;
  SmsSubmission? _latestSms;
  Timer? _calibrationTimer;
  Timer? _countdownRepaintTimer;
  _Page _page = _Page.loading;
  EmergencyContact? _contact;
  String? _error;
  bool _busy = false;
  bool _sensorRunning = false;
  int _calibrationSeconds = 0;
  int _calibrationSamples = 0;
  double _lastRepaintMs = 0;
  double _sampleHz = 0;
  final List<double> _magnitudes = [];
  final RateTracker _rate = RateTracker();
  DateTime? _lastIncidentAt;

  /// Native incident state. The service is the single source of truth: it
  /// detects, counts down, and sends. This screen only renders what the
  /// service reports and forwards the user's intent.
  NativeIncidentSnapshot? _native;
  DetectorDiagnostics? _diagnostics;
  bool get _manual => _native?.manual == true;

  int get _secondsLeft =>
      _native?.counting == true ? _native!.secondsLeft(DateTime.now()) : 0;

  @override
  void initState() {
    super.initState();
    if (widget.testSetupOnly) {
      _page = _Page.setup;
    } else {
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    try {
      _contact = await _contacts.load();
      if (_contact != null) {
        _name.text = _contact!.name;
        _number.text = _contact!.number;
      }
      _batchSub = _sensors.batches.listen(_onBatch);
      _stateSub = _sensors.states.listen((status) {
        if (!mounted) return;
        setState(() {
          _sensorRunning = status.running;
          if (status.error != null) _error = status.error;
        });
      });
      // The service is the detector. Listen to its reports instead of
      // re-deriving them, so there is exactly one incident chain on the device.
      _nativeSub = _gateway.incidents.listen(_onNativeIncident);
      _diagnosticSub = _gateway.diagnostics.listen((value) {
        if (mounted) setState(() => _diagnostics = value);
      });
      _smsStatusSub = _gateway.states.listen((status) {
        if (!mounted) return;
        setState(() => _latestSms = status);
      });
      final prior = await _gateway.outboxSnapshot();
      if (prior.isNotEmpty) _latestSms = prior.first;
      final snapshot = await _gateway.snapshot();
      if (snapshot != null) _native = snapshot;
      await _sensors.attach();
      // Arm on the service side, not the UI side. The countdown then survives
      // this widget being disposed.
      if (_contact != null && _contact!.calibrated == true) {
        if (await _gateway.smsPermissionStatus()) {
          await _gateway.arm(
            contactName: _contact!.name,
            number: _contact!.normalizedNumber,
          );
          await _sensors.start();
          final restored = await _gateway.snapshot();
          if (restored != null) _native = restored;
          if (mounted) {
            setState(() {
              _page = restored?.counting == true
                  ? _Page.incident
                  : (_isTerminal(restored?.stage ?? NativeIncidentStage.idle)
                        ? _Page.result
                        : _Page.guardian);
            });
          }
          unawaited(_prepareModel());
        } else {
          if (mounted) setState(() => _page = _Page.setup);
        }
      } else {
        if (mounted) setState(() => _page = _Page.setup);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Unable to start monitoring: $error';
          _page = _Page.setup;
        });
      }
    }
  }

  Future<void> _prepareModel() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm');
      if (!await file.exists()) return;
      await _path2.prepareFromFile(file.path, backend: PreferredBackend.gpu);
    } catch (_) {
      // Path 1 already has its fixed alert.
    }
  }

  void _onBatch(AccelBatch batch) {
    if (_page == _Page.calibrating) _calibrationSamples += batch.samples.length;
    // Deliberately NOT feeding a Dart-side detector here. FallWatchService owns
    // the CascadeDetector on its own thread, so a second detector in the UI
    // would confirm the same fall twice and send two SMS. The live strip below
    // is the only thing that consumes samples on this side.
    for (final sample in batch.samples) {
      _rate.record(sample.tMs);
      _magnitudes.add(sample.magnitude);
      if (_magnitudes.length > 36) _magnitudes.removeAt(0);
    }
    final last = batch.last.tMs;
    if (mounted && last - _lastRepaintMs >= 200) {
      _lastRepaintMs = last;
      setState(() => _sampleHz = _rate.hz);
    }
  }

  /// The service reports an incident; the UI follows it. */
  void _onNativeIncident(NativeIncidentSnapshot snapshot) {
    if (!mounted) return;
    setState(() {
      _native = snapshot;
      if (snapshot.counting) {
        _page = _Page.incident;
        _lastIncidentAt = DateTime.now();
        _startCountdownRepaint();
      } else if (snapshot.stage == NativeIncidentStage.canceled) {
        _countdownRepaintTimer?.cancel();
        _page = _Page.guardian;
      } else if (_isTerminal(snapshot.stage)) {
        _countdownRepaintTimer?.cancel();
        _page = _Page.result;
      }
    });
  }

  void _startCountdownRepaint() {
    _countdownRepaintTimer?.cancel();
    _countdownRepaintTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _native?.counting == true) setState(() {});
    });
  }

  bool _isTerminal(NativeIncidentStage stage) => switch (stage) {
    NativeIncidentStage.sending ||
    NativeIncidentStage.queued ||
    NativeIncidentStage.sent ||
    NativeIncidentStage.delivered ||
    NativeIncidentStage.failed ||
    NativeIncidentStage.unknown => true,
    _ => false,
  };

  Future<void> _cancelIncident() async {
    final id = _native?.incidentId;
    if (id != null) await _gateway.cancel(id);
  }

  Future<void> _sendIncidentNow() async {
    final id = _native?.incidentId;
    if (id != null) await _gateway.sendNow(id);
  }

  Future<void> _manualSos() async {
    if (_page != _Page.guardian || _contact == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _gateway.startManualSos();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not start SOS: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _beginCalibration() async {
    if (_busy) return;
    final name = _name.text.trim();
    final number = _number.text.trim();
    if (!EmergencyContact.validName(name) ||
        !EmergencyContact.validNumber(number)) {
      setState(() => _error = 'Enter a name and a valid +country-code number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final permitted = await _gateway.requestSmsPermission();
      if (!permitted) {
        setState(
          () => _error = 'SMS permission is required to arm emergency alerts.',
        );
        return;
      }
      _contact = EmergencyContact(name: name, number: number);
      _calibrationSamples = 0;
      _calibrationSeconds = 0;
      await _sensors.start();
      if (!mounted) return;
      setState(() => _page = _Page.calibrating);
      _calibrationTimer?.cancel();
      _calibrationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _page != _Page.calibrating) return;
        setState(() => _calibrationSeconds++);
        if (_calibrationSeconds >= 20) unawaited(_finishCalibration());
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not start sensor: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishCalibration() async {
    _calibrationTimer?.cancel();
    if (_calibrationSamples < 600) {
      setState(() {
        _page = _Page.setup;
        _error = 'Too few sensor samples. Keep Bantay open and try again.';
      });
      return;
    }
    final contact = EmergencyContact(
      name: _contact!.name,
      number: _contact!.normalizedNumber,
      calibrated: true,
    );
    try {
      await _contacts.save(contact);
      _contact = contact;
      await _gateway.arm(
        contactName: contact.name,
        number: contact.normalizedNumber,
      );
      final snapshot = await _gateway.snapshot();
      if (snapshot != null) _native = snapshot;
      if (mounted) setState(() => _page = _Page.guardian);
      unawaited(_prepareModel());
    } catch (error) {
      if (mounted) {
        setState(() {
          _page = _Page.setup;
          _error = 'Could not save contact: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _calibrationTimer?.cancel();
    _batchSub?.cancel();
    _stateSub?.cancel();
    _nativeSub?.cancel();
    _diagnosticSub?.cancel();
    _smsStatusSub?.cancel();
    unawaited(_sensors.dispose());
    unawaited(_path2.dispose());
    _countdownRepaintTimer?.cancel();
    _gateway.dispose();
    _name.dispose();
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = switch (_page) {
      _Page.loading => const Center(child: CircularProgressIndicator()),
      _Page.setup => _buildSetup(),
      _Page.calibrating => _buildCalibration(),
      _Page.guardian => _buildGuardian(),
      _Page.incident => _buildIncident(),
      _Page.result => _buildResult(),
    };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Image.asset(
          'assets/logo.png',
          height: 48,
          alignment: Alignment.centerLeft,
        ),
        actions: [
          if (_page == _Page.guardian)
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Center(
                child: _pill(
                  _sensorRunning ? '◉ Live' : 'Offline',
                  _sensorRunning
                      ? const Color(0xFFD5F0E0)
                      : const Color(0xFFFFE5E5),
                  _sensorRunning ? _green : _red,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: child),
    );
  }

  Widget _buildSetup() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
    children: [
      const Text('SETUP', style: TextStyle(fontSize: 12, letterSpacing: 1.2)),
      const SizedBox(height: 8),
      const Text(
        'Your safety starts here',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'Complete three simple steps to activate your personal safety guardian.',
      ),
      const SizedBox(height: 20),
      const LinearProgressIndicator(
        value: 0.33,
        color: _blue,
        backgroundColor: Color(0xFFDADDE1),
      ),
      const SizedBox(height: 20),
      _sectionCard([
        const Icon(Icons.contacts_outlined, color: _blue, size: 32),
        const SizedBox(height: 12),
        const Text(
          '1. Emergency Contact',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Contact name',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _number,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone number',
            hintText: '+63...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Use the number with country code. Bantay will send a real SMS.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ]),
      const SizedBox(height: 18),
      _sectionCard([
        const Icon(Icons.sensors, color: _blue, size: 32),
        const SizedBox(height: 12),
        const Text(
          '2. Check Sensors',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Keep Bantay open for 20 seconds while Bantay confirms accelerometer readings are arriving.',
        ),
      ]),
      const SizedBox(height: 18),
      _sectionCard([
        const Text(
          '3. Enable Guardian',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Grant SMS permission and start monitoring.'),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!, style: const TextStyle(color: _red)),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _beginCalibration,
        child: Text(_busy ? 'Preparing…' : 'Start Calibration'),
      ),
    ],
  );

  Widget _buildCalibration() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 30, 24, 32),
    children: [
      const Text(
        'Check Sensors',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'Keep your phone nearby. Bantay checks sensor delivery; it does not learn personal movement thresholds.',
      ),
      const SizedBox(height: 36),
      Center(
        child: SizedBox(
          width: 210,
          height: 210,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: _calibrationSeconds / 20,
                  strokeWidth: 12,
                  color: _blue,
                  backgroundColor: _paleBlue,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    (20 - _calibrationSeconds).toString(),
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                      color: _blue,
                    ),
                  ),
                  const Text('seconds remaining'),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 36),
      _sectionCard([
        const Text(
          'Live sensor',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 10),
        Text('$_calibrationSamples samples captured'),
        Text('${_sampleHz.toStringAsFixed(1)} Hz measured'),
      ]),
    ],
  );

  Widget _buildGuardian() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 25, 24, 36),
    children: [
      const Text(
        'Good to have you here!',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      const Text('Your personal safety dashboard'),
      const SizedBox(height: 24),
      _sectionCard([
        Row(
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: const Color(0xFFD5F0E0),
              child: Icon(
                _sensorRunning ? Icons.shield : Icons.shield_outlined,
                color: _green,
                size: 40,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _sensorRunning ? 'Guardian Active' : 'Guardian Offline',
                    style: const TextStyle(
                      fontSize: 20,
                      color: _green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _sensorRunning
                        ? 'Bantay is monitoring your movement and watching for unusual impacts.'
                        : 'Sensor monitoring stopped. Restart the app or check permissions.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ]),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: _statCard(
              Icons.directions_walk,
              'Sensor check',
              _contact?.calibrated == true ? 'Complete' : 'Not ready',
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: _statCard(
              Icons.history,
              'Last Incident',
              _lastIncidentAt != null
                  ? 'Today'
                  : (_latestSms != null ? 'Recorded' : 'None yet'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _sectionCard([
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Movement Activity',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              'Live Sensor',
              style: TextStyle(
                color: _sensorRunning ? _blue : _red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 80,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final magnitude in _magnitudes)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: math.max(4, math.min(78, magnitude * 55)),
                      decoration: BoxDecoration(
                        color: const Color(0xFF99CCFF),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${_sampleHz.toStringAsFixed(1)} samples/sec measured',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        // Detector state, straight from the service. Debug-only, and never a
        // gate on the alert: the cascade that decides the incident runs in
        // FallWatchService and does not consult this widget.
        if (_diagnostics != null) ...[
          const SizedBox(height: 4),
          Text(
            'Detector: peak ${(_diagnostics!.lastPeakG ?? 0).toStringAsFixed(2)}g, '
            'rotation ${(_diagnostics!.rotationDegrees ?? 0).toStringAsFixed(0)}°, '
            '${_diagnostics!.impactThresholdCrossed ? "impact seen" : "no impact"}'
            '${_diagnostics!.rejectReason == null || _diagnostics!.rejectReason == "none" ? "" : ", ${_diagnostics!.rejectReason}"}',
            style: const TextStyle(fontSize: 11, color: Colors.black38),
          ),
        ],
      ]),
      const SizedBox(height: 22),
      FilledButton(
        onPressed: _sensorRunning && !_busy ? _manualSos : null,
        child: const Text('I Need Help'),
      ),
      if (_latestSms != null) ...[
        const SizedBox(height: 18),
        _sectionCard([
          const Text(
            'Latest SMS status',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(_latestSms!.state.name.toUpperCase()),
          if (_latestSms!.error != null)
            Text(
              _latestSms!.error!,
              style: const TextStyle(color: _red, fontSize: 12),
            ),
        ]),
      ],
      const SizedBox(height: 18),
      Row(
        children: [
          const Icon(Icons.person_outline, color: _blue),
          const SizedBox(width: 10),
          Expanded(child: Text('Contact: ${_contact?.name ?? 'Not set'}')),
        ],
      ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!, style: const TextStyle(color: _red)),
      ],
    ],
  );

  Widget _buildIncident() => ListView(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
    children: [
      const Center(
        child: CircleAvatar(
          radius: 46,
          backgroundColor: Color(0xFFFFE5E5),
          child: Icon(Icons.warning_rounded, color: _red, size: 54),
        ),
      ),
      const SizedBox(height: 18),
      Center(
        child: Text(
          _manual ? 'Do you need help?' : 'Are you okay?',
          style: const TextStyle(
            fontSize: 26,
            color: _red,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Center(
        child: Text(
          _manual
              ? 'Your emergency message is ready to send.'
              : 'A sudden impact was detected, followed by limited movement.',
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 24),
      _sectionCard([
        Center(
          child: Text(
            _secondsLeft.toString(),
            style: const TextStyle(
              fontSize: 72,
              color: _red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const Center(child: Text('AUTOMATIC ALERT IN')),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '$_secondsLeft seconds',
            style: const TextStyle(color: _red, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 18),
        LinearProgressIndicator(
          value: _secondsLeft / 15,
          color: _red,
          backgroundColor: const Color(0xFFFFE5E5),
        ),
      ]),
      const SizedBox(height: 18),
      if (!_manual)
        _sectionCard([
          const Text(
            'Incident Details',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: _red,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Impact strength: ${_native?.peakG?.toStringAsFixed(1) ?? 'unavailable'} g',
          ),
          Text(
            'Limited movement: ${_native?.stillnessSeconds ?? 0} seconds',
          ),
          Text('Detected at: ${_native?.occurredAt?.toLocal() ?? 'unavailable'}'),
        ]),
      if (!_manual) const SizedBox(height: 18),
      _sectionCard([
        const Text(
          'Message preview',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(_native?.text ?? ''),
      ]),
      const SizedBox(height: 22),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: _red),
        onPressed: () => unawaited(_sendIncidentNow()),
        child: const Text('SEND HELP NOW'),
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: () => unawaited(_cancelIncident()),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: const BorderSide(color: _blue),
        ),
        child: const Text("I'M OK — CANCEL ALERT"),
      ),
    ],
  );

  Widget _buildResult() {
    final stage = _native?.stage ?? NativeIncidentStage.sending;
    final title = switch (stage) {
      NativeIncidentStage.sent || NativeIncidentStage.delivered => 'Emergency Alert Sent',
      NativeIncidentStage.queued => 'Emergency Alert Queued',
      NativeIncidentStage.failed || NativeIncidentStage.unknown => 'Emergency Alert Failed',
      _ => 'Sending Emergency Alert',
    };
    final detail = switch (stage) {
      NativeIncidentStage.sent => 'Carrier accepted the SMS.',
      NativeIncidentStage.delivered => 'Carrier reports SMS delivered.',
      NativeIncidentStage.queued => _native?.error ?? 'SMS queued for retry when service is available.',
      NativeIncidentStage.failed || NativeIncidentStage.unknown =>
        _native?.error ?? 'The SMS outcome needs checking before retry.',
      _ => 'Waiting for the carrier response.',
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
      children: [
        Center(
          child: CircleAvatar(
            radius: 46,
            backgroundColor: stage == NativeIncidentStage.failed || stage == NativeIncidentStage.unknown
                ? const Color(0xFFFFE5E5)
                : const Color(0xFFD5F0E0),
            child: Icon(
              stage == NativeIncidentStage.failed || stage == NativeIncidentStage.unknown
                  ? Icons.error_outline
                  : Icons.mark_email_read_outlined,
              color: stage == NativeIncidentStage.failed || stage == NativeIncidentStage.unknown ? _red : _green,
              size: 48,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            title,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 8),
        Center(child: Text(detail, textAlign: TextAlign.center)),
        const SizedBox(height: 24),
        _sectionCard([
          const Text(
            'Emergency contact',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            '${_contact?.name ?? ''}  •  ${_contact?.normalizedNumber ?? ''}',
          ),
        ]),
        const SizedBox(height: 16),
        _sectionCard([
          const Text(
            'Exact SMS text',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(_native?.text ?? ''),
          const SizedBox(height: 12),
          Text(
            'Reliable fixed wording',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () {
            setState(() => _page = _Page.guardian);
          },
          child: const Text('Back to Guardian'),
        ),
      ],
    );
  }

  Widget _sectionCard(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
  Widget _statCard(IconData icon, String title, String value) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _paleBlue,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        Icon(icon, color: _blue),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
  Widget _pill(String text, Color background, Color foreground) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(color: foreground, fontWeight: FontWeight.bold),
    ),
  );
}
