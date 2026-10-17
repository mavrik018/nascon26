import 'package:flutter/material.dart';

import '../../core/app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url;
  String? _result;
  bool _busy = false;

  static const _presets = {'Emulator': 'http://10.0.2.2:8080'};

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: AppScope.read(context).baseUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = AppScope.read(context);
    if (_url.text.trim().isEmpty) {
      setState(() => _result = 'Please enter the server address.');
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    await state.setBaseUrl(_url.text);
    final result = await state.testConnection();
    if (!mounted) return;
    _url.text = state.baseUrl;
    setState(() {
      _busy = false;
      _result = 'Saved. $result';
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Server settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'The app talks to the league server on the team laptop. '
            'Use 10.0.2.2 on the emulator, or the laptop\'s Wi-Fi IP address on a phone.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('server-url'),
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'http://192.168.1.10:8080',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _presets.entries)
                ActionChip(
                  label: Text('${e.key}: ${e.value.replaceFirst('http://', '')}'),
                  onPressed: () => setState(() => _url.text = e.value),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_busy ? 'Checking…' : 'Save and test connection'),
          ),
          if (_result != null) ...[const SizedBox(height: 12), Semantics(liveRegion: true, child: Text(_result!))],
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.phone_android),
            title: const Text('Device id (used for offline sync)'),
            subtitle: Text(state.deviceId),
          ),
        ],
      ),
    );
  }
}
