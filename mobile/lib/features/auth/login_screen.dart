import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/models.dart';
import '../settings/settings_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  static const demoPassword = 'Nascon@26';
  static const demoAccounts = {
    'Organizer': 'organizer@nascon.test',
    'Club manager': 'manager@nascon.test',
    'Player': 'player@nascon.test',
    'Viewer': 'viewer@nascon.test',
    'Admin': 'admin@nascon.test',
  };

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _fill(String email) {
    setState(() {
      _email.text = email;
      _password.text = LoginScreen.demoPassword;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).login(_email.text, _password.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.status == 401 ? 'That email or password is not correct.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final error = _error ?? state.sessionNotice;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        actions: [
          IconButton(
            tooltip: 'Server settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.sports_soccer, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 8),
                    Text('League Manager', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text('Server: ${state.baseUrl}', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 24),
                    TextFormField(
                      key: const Key('email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Enter your email address' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('password'),
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscure ? 'Show password' : 'Hide password',
                          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: theme.colorScheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('sign-in'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    if (state.savedAccounts.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text('Continue as (saved on this phone, works offline)', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      for (final a in state.savedAccounts)
                        Card(
                          margin: const EdgeInsets.only(top: 8),
                          child: ListTile(
                            key: Key('saved-${a.user.email}'),
                            leading: const Icon(Icons.account_circle_outlined),
                            title: Text(Roles.label(a.user.role)),
                            subtitle: Text(a.user.email),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _busy ? null : () => state.continueAs(a),
                          ),
                        ),
                    ],
                    const SizedBox(height: 24),
                    Text('Demo accounts (tap to fill)', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in LoginScreen.demoAccounts.entries)
                          ActionChip(
                            key: Key('demo-${e.value}'),
                            avatar: const Icon(Icons.person_outline, size: 18),
                            label: Text(e.key),
                            tooltip: 'Fill in ${e.value}',
                            onPressed: () => _fill(e.value),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
