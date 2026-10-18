import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ocean_widgets.dart' show ink, muted, ocean;

/// iOS-style building blocks from `Desktop/IOS design` (feedback toasts, action-sheet picker, grouped forms,
/// alerts) plus the app's motion tokens. Every screen uses these instead of Material defaults.

// --------------------------------------------------------------------------- motion tokens

/// Shared durations (exit ~65% of enter) and curves, so every animation has the same rhythm.
abstract final class Motion {
  static const enter = Duration(milliseconds: 280);
  static const exit = Duration(milliseconds: 180);
  static const quick = Duration(milliseconds: 150);
  static const curve = Curves.easeOutCubic;

  /// Respects the phone's "Reduce motion" setting.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Fades and lifts its child into place once, when first shown (staggered by [index]).
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  // The stagger lives inside the animation (an Interval), so no timer outlives the widget.
  late final int _delayMs = 40 * widget.index.clamp(0, 6);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.enter + Duration(milliseconds: _delayMs),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return widget.child;
    final start = _delayMs / (_delayMs + Motion.enter.inMilliseconds);
    final t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: Motion.curve),
    );
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(t),
        child: widget.child,
      ),
    );
  }
}

// --------------------------------------------------------------------------- toasts

enum ToastKind { success, error, info }

/// One quiet floating receipt (iOS HUD style). Replaces any toast already showing, never queues.
/// [actionLabel] + [onAction] add one button (e.g. "View cart"); [onRetry] is the same with label "Retry".
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  VoidCallback? onRetry,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger != null) {
    toastOn(messenger, message, kind: kind, onRetry: onRetry, actionLabel: actionLabel, onAction: onAction);
  }
}

void toastOn(
  ScaffoldMessengerState messenger,
  String message, {
  ToastKind kind = ToastKind.info,
  VoidCallback? onRetry,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final action = onRetry ?? onAction;
  final label = onRetry != null ? 'Retry' : actionLabel;
  final (IconData icon, Color tint) = switch (kind) {
    ToastKind.success => (CupertinoIcons.check_mark_circled_solid, const Color(0xFF30D158)),
    ToastKind.error => (CupertinoIcons.exclamationmark_circle_fill, const Color(0xFFFF453A)),
    ToastKind.info => (CupertinoIcons.info_circle_fill, const Color(0xFF64D2FF)),
  };
  if (kind == ToastKind.error) {
    HapticFeedback.mediumImpact();
  } else {
    HapticFeedback.lightImpact();
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: const Color(0xF21C1C1E),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        dismissDirection: DismissDirection.down,
        duration: Duration(milliseconds: action == null ? 2800 : 5000),
        content: Semantics(
          liveRegion: true,
          child: Row(
            children: [
              Icon(icon, color: tint, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
                ),
              ),
              if (action != null && label != null)
                TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    action();
                  },
                  style: TextButton.styleFrom(foregroundColor: tint, minimumSize: const Size(48, 44)),
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
            ],
          ),
        ),
      ),
    );
}

// --------------------------------------------------------------------------- alerts

/// Cupertino confirm dialog. Returns true only when the user confirms.
Future<bool> confirmIos(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Confirm',
  bool destructive = false,
}) async {
  HapticFeedback.selectionClick();
  final ok = await showCupertinoDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        CupertinoDialogAction(
          isDefaultAction: !destructive,
          isDestructiveAction: destructive,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  if (ok == true) {
    if (destructive) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
  }
  return ok == true;
}

// --------------------------------------------------------------------------- action-sheet picker

class PickerOption<T> {
  const PickerOption({required this.value, required this.label, this.subtitle, this.icon, this.destructive = false});
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool destructive;
}

/// Single-select bottom action sheet (replaces Material dropdowns): tick on the selected row,
/// separate Cancel card, selection haptics, scrolls past 60% of the screen.
Future<T?> showIosPicker<T>(
  BuildContext context, {
  required List<PickerOption<T>> options,
  String? title,
  String? message,
  T? selected,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .6),
              decoration: BoxDecoration(color: const Color(0xFFF7FAFC), borderRadius: BorderRadius.circular(24)),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  if (title != null || message != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Column(
                        children: [
                          if (title != null)
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: muted),
                            ),
                          if (message != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                message,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 13, color: muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                  for (final (i, o) in options.indexed) ...[
                    if (i > 0 || title != null || message != null) const Divider(height: 1, indent: 20),
                    InkWell(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        Navigator.pop(ctx, o.value);
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 52),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                          child: Row(
                            children: [
                              if (o.icon != null) ...[
                                Icon(o.icon, size: 22, color: o.destructive ? const Color(0xFFD70015) : ocean),
                                const SizedBox(width: 14),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      o.label,
                                      style: TextStyle(
                                        fontSize: 17,
                                        color: o.destructive ? const Color(0xFFD70015) : ink,
                                      ),
                                    ),
                                    if (o.subtitle != null)
                                      Text(o.subtitle!, style: const TextStyle(fontSize: 13, color: muted)),
                                  ],
                                ),
                              ),
                              if (o.value == selected)
                                const Icon(
                                  CupertinoIcons.check_mark,
                                  color: ocean,
                                  size: 20,
                                  semanticLabel: 'Selected',
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => Navigator.pop(ctx),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Cancel',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ocean),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// --------------------------------------------------------------------------- grouped forms

/// Inset grouped card: UPPERCASE header, rows separated by inset hairlines, optional footer.
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.children, this.header, this.footer});
  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (header != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            header!.toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .6, color: Colors.white),
          ),
        ),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF041524).withValues(alpha: .12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: ocean.withValues(alpha: .08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) const Divider(height: 1, thickness: .6, indent: 16, color: Color(0xFFD5E3EC)),
                child,
              ],
            ],
          ),
        ),
      ),
      if (footer != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(footer!, style: const TextStyle(fontSize: 12.5, color: Colors.white, height: 1.35)),
        ),
    ],
  );
}

const _rowDecoration = InputDecoration(
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  filled: false,
  isDense: true,
  contentPadding: EdgeInsets.symmetric(vertical: 4),
);

/// One text input row inside a [FormSection]: small label above a borderless field, error under it.
class TextRow extends StatelessWidget {
  const TextRow({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.validator,
    this.keyboardType,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.none,
    this.fieldKey,
    this.obscureText = false,
    this.suffix,
    this.prefixIcon,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autofillHints,
  });
  final String label;
  final TextEditingController controller;
  final String? hint;
  final FormFieldValidator<String>? validator;
  final TextInputType? keyboardType;
  final int maxLines;
  final TextCapitalization textCapitalization;
  final Key? fieldKey;
  final bool obscureText;
  final Widget? suffix;
  final IconData? prefixIcon;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final Iterable<String>? autofillHints;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 10, suffix == null ? 16 : 4, 8),
    child: TextFormField(
      key: fieldKey,
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      maxLines: maxLines,
      obscureText: obscureText,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      autofillHints: autofillHints,
      style: const TextStyle(fontSize: 16, color: ink),
      decoration: _rowDecoration.copyWith(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, color: muted, size: 20),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: const TextStyle(fontSize: 13, color: muted, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// A tappable form row that opens [showIosPicker]: label left, value pill and chevron right.
/// It is a real FormField, so `validator` errors show under the row like any other field.
class PickerRow<T> extends FormField<T> {
  PickerRow({
    super.key,
    required String label,
    required List<PickerOption<T>> options,
    required T initialValue,
    required ValueChanged<T> onChanged,
    String? sheetTitle,
    super.validator,
  }) : super(
         initialValue: initialValue,
         builder: (field) {
           final current = options.where((o) => o.value == field.value).firstOrNull;
           return Semantics(
             button: true,
             label: '$label, ${current?.label ?? 'not set'}. Change.',
             excludeSemantics: true,
             child: InkWell(
               onTap: () async {
                 final picked = await showIosPicker<T>(
                   field.context,
                   title: sheetTitle ?? label,
                   options: options,
                   selected: field.value,
                 );
                 if (picked != null) {
                   field.didChange(picked);
                   onChanged(picked);
                 }
               },
               child: ConstrainedBox(
                 constraints: const BoxConstraints(minHeight: 52),
                 child: Padding(
                   padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: [
                       Row(
                         children: [
                           Expanded(
                             child: Text(label, style: const TextStyle(fontSize: 16, color: ink)),
                           ),
                           Flexible(
                             child: Container(
                               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                               decoration: BoxDecoration(
                                 color: ocean.withValues(alpha: .08),
                                 borderRadius: BorderRadius.circular(999),
                               ),
                               child: Text(
                                 current?.label ?? 'Choose',
                                 maxLines: 1,
                                 overflow: TextOverflow.ellipsis,
                                 style: const TextStyle(fontSize: 15, color: ocean, fontWeight: FontWeight.w600),
                               ),
                             ),
                           ),
                           const SizedBox(width: 6),
                           const Icon(CupertinoIcons.chevron_right, size: 15, color: muted),
                         ],
                       ),
                       if (field.errorText != null)
                         Padding(
                           padding: const EdgeInsets.only(top: 4),
                           child: Text(
                             field.errorText!,
                             style: const TextStyle(color: Color(0xFFB3261E), fontSize: 12),
                           ),
                         ),
                     ],
                   ),
                 ),
               ),
             ),
           );
         },
       );
}

/// An on/off row inside a [FormSection] (Cupertino switch).
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.label, required this.value, required this.onChanged, this.subtitle});
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 16, color: ink)),
                  if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 12.5, color: muted)),
                ],
              ),
            ),
            CupertinoSwitch(
              value: value,
              activeTrackColor: ocean,
              onChanged: (v) {
                HapticFeedback.selectionClick();
                onChanged(v);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// Full-width primary action with a spinner while busy (shared by every form).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 54)),
      onPressed: busy || onPressed == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              onPressed!();
            },
      child: AnimatedSwitcher(
        duration: Motion.quick,
        child: busy
            ? const SizedBox.square(
                key: ValueKey('busy'),
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Row(
                key: const ValueKey('label'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                  Text(label),
                ],
              ),
      ),
    ),
  );
}

/// Inline error banner for forms (plain language, icon + text, never colour alone).
class FormError extends StatelessWidget {
  const FormError(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFDECEA),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFFF5C2BE)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(CupertinoIcons.exclamationmark_triangle_fill, color: Color(0xFFB3261E), size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: const TextStyle(color: Color(0xFF8C1D18), fontSize: 13.5)),
        ),
      ],
    ),
  );
}

/// A tappable row showing a value (label left, value pill + chevron right), e.g. a date.
class ValueRow extends StatelessWidget {
  const ValueRow({super.key, required this.label, required this.value, required this.onTap, this.icon});
  final String label;
  final String value;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label, $value. Change.',
    excludeSemantics: true,
    child: InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 20, color: ocean), const SizedBox(width: 10)],
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 16, color: ink)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: ocean.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  value,
                  style: const TextStyle(fontSize: 15, color: ocean, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(CupertinoIcons.chevron_right, size: 15, color: muted),
            ],
          ),
        ),
      ),
    ),
  );
}

/// iOS date wheel in a bottom sheet with Cancel / Done. Returns null when cancelled.
Future<DateTime?> showIosDatePicker(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) {
  var picked = initial.isBefore(first) ? first : (initial.isAfter(last) ? last : initial);
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: const Color(0xFFF7FAFC), borderRadius: BorderRadius.circular(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                CupertinoButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                const Spacer(),
                CupertinoButton(
                  onPressed: () => Navigator.pop(ctx, picked),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            SizedBox(
              height: 216,
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: picked,
                minimumDate: first,
                maximumDate: last,
                onDateTimeChanged: (d) {
                  HapticFeedback.selectionClick();
                  picked = d;
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
