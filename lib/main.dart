import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const ApduPosApp());

class ApduPosApp extends StatelessWidget {
  const ApduPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'APDU POS',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
      ),
      home: const HomePage(),
    );
  }
}

/// Thin Dart wrapper around the Kotlin MethodChannel handler in MainActivity.
class Telephony {
  static const _ch = MethodChannel('apdu_pos/telephony');

  static Future<bool> hasCarrierPrivileges({int slot = 0}) async {
    final v =
        await _ch.invokeMethod<bool>('hasCarrierPrivileges', {'slot': slot});
    return v ?? false;
  }

  static Future<List<Map<String, dynamic>>> listSlots() async {
    final v = await _ch.invokeMethod<List<dynamic>>('listSlots');
    return (v ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Returns map with: status (int), channel (int), selectResponse (hex string).
  static Future<Map<String, dynamic>> openLogicalChannel({
    required int slot,
    required String aid,
    int p2 = 0,
  }) async {
    final v = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'openLogicalChannel', {'slot': slot, 'aid': aid, 'p2': p2});
    return Map<String, dynamic>.from(v ?? {});
  }

  /// Returns the response APDU as a hex string (data + SW1 SW2).
  static Future<String> transmitApdu({
    required int slot,
    required int channel,
    required int cla,
    required int ins,
    required int p1,
    required int p2,
    required int p3,
    required String dataHex,
  }) async {
    final v = await _ch.invokeMethod<String>('transmitApdu', {
      'slot': slot,
      'channel': channel,
      'cla': cla,
      'ins': ins,
      'p1': p1,
      'p2': p2,
      'p3': p3,
      'data': dataHex,
    });
    return v ?? '';
  }

  static Future<bool> closeLogicalChannel({
    required int slot,
    required int channel,
  }) async {
    final v = await _ch.invokeMethod<bool>(
        'closeLogicalChannel', {'slot': slot, 'channel': channel});
    return v ?? false;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _slotCtrl = TextEditingController(text: '0');
  // ARA-M AID is a useful smoke test if the eSIM exposes one.
  final _aidCtrl = TextEditingController(text: 'A00000015141434C00');
  final _p2Ctrl = TextEditingController(text: '0');
  // Default APDU: SELECT by AID — replace with whatever your applet expects.
  final _apduCtrl = TextEditingController(text: '80CA00A000');

  int? _openChannel;
  String _lastSelectResponse = '';
  int _lastSelectStatus = -1;
  final List<String> _log = [];
  bool _busy = false;
  bool? _hasPrivileges;

  @override
  void initState() {
    super.initState();
    _refreshPrivileges();
  }

  Future<void> _refreshPrivileges() async {
    try {
      final has = await Telephony.hasCarrierPrivileges(slot: _slot);
      setState(() => _hasPrivileges = has);
    } on PlatformException catch (e) {
      _push('hasCarrierPrivileges error: ${e.code} ${e.message}');
    }
  }

  int get _slot => int.tryParse(_slotCtrl.text.trim()) ?? 0;

  void _push(String line) {
    setState(() {
      _log.insert(0, '${TimeOfDay.now().format(context)}  $line');
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _runGuarded(String label, Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on PlatformException catch (e) {
      _push('$label ${e.code}: ${e.message}');
    } catch (e) {
      _push('$label exception: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openChannelTap() => _runGuarded('open', () async {
        final aid = _aidCtrl.text.trim().replaceAll(' ', '');
        final p2 = int.tryParse(_p2Ctrl.text.trim()) ?? 0;
        final r =
            await Telephony.openLogicalChannel(slot: _slot, aid: aid, p2: p2);
        final ch = r['channel'] as int? ?? -1;
        final st = r['status'] as int? ?? -1;
        final sel = (r['selectResponse'] as String?) ?? '';
        setState(() {
          _openChannel = ch >= 0 ? ch : null;
          _lastSelectStatus = st;
          _lastSelectResponse = sel;
        });
        _push('open  AID=$aid  → channel=$ch status=$st select="$sel"');
      });

  Future<void> _transmitTap() => _runGuarded('transmit', () async {
        final ch = _openChannel;
        if (ch == null) {
          _push('transmit: no open channel — call Open first');
          return;
        }
        final apdu = _parseApdu(_apduCtrl.text);
        if (apdu == null) {
          _push(
              'transmit: APDU must be >= 4 hex bytes (CLA INS P1 P2 [Lc Data] [Le])');
          return;
        }
        final resp = await Telephony.transmitApdu(
          slot: _slot,
          channel: ch,
          cla: apdu.cla,
          ins: apdu.ins,
          p1: apdu.p1,
          p2: apdu.p2,
          p3: apdu.p3,
          dataHex: apdu.data,
        );
        _push('xmit  ${_apduCtrl.text.trim()}  → $resp');
      });

  Future<void> _closeChannelTap() => _runGuarded('close', () async {
        final ch = _openChannel;
        if (ch == null) {
          _push('close: no open channel');
          return;
        }
        final ok =
            await Telephony.closeLogicalChannel(slot: _slot, channel: ch);
        _push('close channel=$ch → $ok');
        setState(() => _openChannel = null);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('APDU POS'),
        actions: [
          IconButton(
            tooltip: 'Re-check carrier privileges',
            onPressed: _refreshPrivileges,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _privilegeBanner(theme),
              const SizedBox(height: 8),
              _slotCard(),
              const SizedBox(height: 8),
              _openCard(),
              const SizedBox(height: 8),
              _transmitCard(),
              const SizedBox(height: 8),
              _closeCard(),
              const SizedBox(height: 12),
              Text('Log', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _log.isEmpty ? '(empty)' : _log.join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _privilegeBanner(ThemeData theme) {
    final p = _hasPrivileges;
    final color = p == true
        ? Colors.green.shade100
        : p == false
            ? Colors.red.shade100
            : theme.colorScheme.surfaceContainerHighest;
    final text = p == null
        ? 'Carrier privileges: checking…'
        : p
            ? 'Carrier privileges: GRANTED on slot $_slot'
            : 'Carrier privileges: NOT granted on slot $_slot. '
                'APDU calls will throw SecurityException unless this app is '
                'platform-signed or the eSIM has an ARA-M rule for this cert.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
      child: Text(text),
    );
  }

  Widget _slotCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('SIM slot'),
              const SizedBox(width: 12),
              SizedBox(
                width: 60,
                child: TextField(
                  controller: _slotCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (_) => _refreshPrivileges(),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                  onPressed: _refreshPrivileges, child: const Text('Check')),
            ],
          ),
        ),
      );

  Widget _openCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('1) Open Logical Channel',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _aidCtrl,
                decoration: const InputDecoration(
                    labelText: 'AID (hex)', isDense: true),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Text('P2'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _p2Ctrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _openChannelTap,
                  child: const Text('Open'),
                ),
              ]),
              if (_openChannel != null) ...[
                const SizedBox(height: 8),
                Text(
                    'channel=$_openChannel  status=$_lastSelectStatus  selectResp=$_lastSelectResponse',
                    style: const TextStyle(fontFamily: 'monospace')),
              ],
            ],
          ),
        ),
      );

  Widget _transmitCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('2) Transmit APDU',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _apduCtrl,
                decoration: const InputDecoration(
                    labelText: 'APDU hex (CLA INS P1 P2 [Lc Data] [Le])',
                    isDense: true),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _openChannel == null ? null : _transmitTap,
                  child: const Text('Transmit'),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _closeCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('3) Close Logical Channel',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton(
                onPressed: _openChannel == null ? null : _closeChannelTap,
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );

  /// Parse a hex APDU string into TelephonyManager's 7 fields.
  /// Accepts case-3 (no Le), case-4 (with Le), or case-1/case-2 short form.
  ///   Format: CLA INS P1 P2 [Lc Data] [Le]
  /// TelephonyManager's `p3` is Lc for outbound data, or Le for case-2/4.
  _Apdu? _parseApdu(String input) {
    final s = input.replaceAll(RegExp(r'\s+'), '');
    if (s.length < 8 || s.length % 2 != 0) return null;
    final bytes = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      final b = int.tryParse(s.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      bytes.add(b);
    }
    final cla = bytes[0];
    final ins = bytes[1];
    final p1 = bytes[2];
    final p2 = bytes[3];
    int p3 = 0;
    String data = '';
    if (bytes.length == 4) {
      // case 1: no Lc, no Le → p3 = 0, empty data
      p3 = 0;
    } else if (bytes.length == 5) {
      // case 2 short: Le only
      p3 = bytes[4];
    } else {
      // case 3 / 4 short: Lc + data [+ Le]
      final lc = bytes[4];
      if (bytes.length >= 5 + lc) {
        p3 = lc;
        data = s.substring(10, 10 + lc * 2);
        // case 4 short with trailing Le is ignored — the kernel re-issues
        // GET RESPONSE itself based on SW=61xx / 6Cxx. If you need explicit
        // Le, append it to `data` per device behaviour.
      } else {
        return null;
      }
    }
    return _Apdu(cla, ins, p1, p2, p3, data);
  }
}

class _Apdu {
  final int cla, ins, p1, p2, p3;
  final String data;
  _Apdu(this.cla, this.ins, this.p1, this.p2, this.p3, this.data);
}
