import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/format.dart';
import '../../widgets/common.dart';

/// In-app receipt view built from the checkout response, plus PDF open/save.
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.order});
  final Map<String, dynamic> order;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  String? _savedPath;
  bool _busy = false;

  Map<String, dynamic> get _receipt => asMap(widget.order['receipt']);
  Map<String, dynamic> get _payload => asMap(_receipt['payload']);

  Future<String?> _savePdf() async {
    final b64 = asStr(_receipt['pdf_base64']);
    if (b64.isEmpty) {
      showSnack(context, 'The server did not include a PDF for this receipt.', error: true);
      return null;
    }
    final bytes = base64Decode(b64);
    final dir = await getApplicationDocumentsDirectory();
    final orderId = asStr(widget.order['order_id'], 'order').replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final file = File(p.join(dir.path, 'receipt-$orderId.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _openPdf() async {
    setState(() => _busy = true);
    try {
      final path = await _savePdf();
      if (path == null || !mounted) return;
      setState(() => _savedPath = path);
      final result = await OpenFilex.open(path, type: 'application/pdf');
      if (!mounted) return;
      if (result.type != ResultType.done) {
        showSnack(context, 'PDF saved. No PDF viewer app was found to open it.');
      }
    } on FormatException {
      if (mounted) showSnack(context, 'The receipt PDF could not be read.', error: true);
    } on FileSystemException {
      if (mounted) showSnack(context, 'The receipt PDF could not be saved on this phone.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = widget.order;
    final payload = _payload;
    final currency = asStr(order['currency'] ?? payload['currency'], 'PKR');
    final items = [for (final i in asList(order['items'] ?? payload['items'])) asMap(i)];
    final labels = asMap(order['local_labels']);
    final payment = asMap(order['payment']);
    final discount = asInt(order['discount_minor'] ?? payload['discount_minor']);
    final paidAt = asStr(payload['paid_at']);
    final signature = asStr(_receipt['signature']);
    Widget line(String label, String value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: bold ? theme.textTheme.titleMedium : null)),
          Text(
            value,
            style: bold ? theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold) : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: leagueAppBar(context, 'Receipt'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 40, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          asStr(order['status']) == 'paid' ? 'Payment successful' : humanize(asStr(order['status'])),
                          style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                        ),
                        Text(
                          'Order ${asStr(order['order_id'])}',
                          style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order summary', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final i in items)
                    line(
                      '${asStr(labels[i['variant_id']], asStr(i['variant_id']))} × ${i['quantity']}',
                      formatMoney(asInt(i['unit_price_minor']) * asInt(i['quantity'], 1), currency),
                    ),
                  const Divider(),
                  line('Subtotal', formatMoney(asInt(order['subtotal_minor'] ?? payload['subtotal_minor']), currency)),
                  if (discount > 0) line('Discount', '-${formatMoney(discount, currency)}'),
                  line(
                    'Total paid',
                    formatMoney(asInt(order['total_minor'] ?? payload['total_minor']), currency),
                    bold: true,
                  ),
                  const SizedBox(height: 8),
                  if (paidAt.isNotEmpty) Text('Paid ${formatDateTime(paidAt)}'),
                  if (payment.isNotEmpty) Text('Payment ${humanize(asStr(payment['state']))}'),
                  if (signature.isNotEmpty)
                    Text(
                      'Signed receipt ${signature.length > 12 ? '${signature.substring(0, 12)}…' : signature}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('open-pdf'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _busy ? null : _openPdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Open PDF receipt'),
          ),
          if (_savedPath != null) ...[
            const SizedBox(height: 8),
            Text('Saved on this phone: $_savedPath', style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: const Text('Back to home'),
          ),
        ],
      ),
    );
  }
}
