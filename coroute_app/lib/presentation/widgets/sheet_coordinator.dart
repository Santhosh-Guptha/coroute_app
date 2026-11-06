import 'package:flutter/material.dart';

import '../../core/ui/ui.dart';

/// One cockpit pop-up at a time.
///
/// Every cockpit button that opens a pop-up (a sheet, a dialog or a panel)
/// goes through [present]:
///
/// * a pop-up that is already open is closed first, so pop-ups never pile up
///   on top of each other;
/// * the same button again closes its own pop-up (it toggles);
/// * a `protected` pop-up (an SOS step, the crash check, a payment in
///   progress) is never closed or covered from here: it closes only through
///   its own buttons.
///
/// Closing by a tap outside (on the scrim) and by the back button is done by
/// the pop-up's own route: [showAppSheet], `showDialog` and [showPopupPanel]
/// are all dismissible that way, except [showProtectedDialog].
class SheetCoordinator {
  SheetCoordinator._();

  /// The one coordinator of the app (there is one cockpit).
  static final SheetCoordinator instance = SheetCoordinator._();

  _OpenPopup? _open;

  /// Key of the pop-up open now, null when none is.
  Object? get currentKey => _open?.key;

  /// Whether a pop-up opened through the coordinator is open.
  bool get hasOpen => _open != null;

  /// Whether the pop-up with [key] is the one open now.
  bool isOpen(Object key) => _open?.key == key;

  /// Opens a pop-up with [open] (any function that pushes one route
  /// synchronously: [showAppSheet], `showModalBottomSheet`, `showDialog`,
  /// [showPopupPanel] or a `XSheet.show`), first closing the one already open.
  ///
  /// When the pop-up with [key] is already open it is closed instead and
  /// nothing new opens ([toggle] false: left open). While a protected pop-up
  /// is open nothing else opens. Completes with the pop-up's result (null
  /// when nothing opened).
  Future<T?> present<T>(
    BuildContext context, {
    required Object key,
    required Future<T?> Function() open,
    bool protected = false,
    bool toggle = true,
  }) {
    final current = _open;
    if (current != null) {
      if (current.key == key) {
        if (toggle && !current.protected) _close(current);
        return Future<T?>.value();
      }
      if (current.protected) return Future<T?>.value();
      _close(current);
    }
    final navigator = Navigator.maybeOf(context);
    final before = navigator == null ? null : _topRoute(navigator);
    final future = open();
    final top = navigator == null ? null : _topRoute(navigator);
    final entry = _OpenPopup(key, protected: protected, route: identical(top, before) ? null : top);
    _open = entry;
    void done() {
      if (identical(_open, entry)) _open = null;
    }
    future.then<void>((_) => done(), onError: (Object error, StackTrace stack) => done());
    return future;
  }

  /// Records a pop-up drawn inside a screen (not a route) as the open one:
  /// opening another pop-up calls [close] first. Pair with [detach].
  void attach(Object key, VoidCallback close, {bool protected = false}) {
    final current = _open;
    if (current != null && current.key != key) _close(current);
    _open = _OpenPopup(key, protected: protected, onClose: close);
  }

  /// The in-screen pop-up with [key] closed by itself.
  void detach(Object key) {
    if (_open?.key == key) _open = null;
  }

  /// Closes the open pop-up (only when it has [key], if given). A protected
  /// pop-up is never closed from here. Returns whether one was closed.
  bool close([Object? key]) {
    final current = _open;
    if (current == null || (key != null && current.key != key) || current.protected) return false;
    _close(current);
    return true;
  }

  /// Forgets the open pop-up without closing it (tests).
  @visibleForTesting
  void reset() => _open = null;

  void _close(_OpenPopup popup) {
    if (identical(_open, popup)) _open = null;
    final onClose = popup.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    final route = popup.route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// The route on top of [navigator] (popUntil stops at once: nothing pops).
  static Route<dynamic>? _topRoute(NavigatorState navigator) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }
}

class _OpenPopup {
  final Object key;
  final bool protected;
  final Route<dynamic>? route;
  final VoidCallback? onClose;
  _OpenPopup(this.key, {required this.protected, this.route, this.onClose});
}

/// A floating panel (a menu, a quick-access card) placed anywhere on the
/// screen, as a real modal route: the cockpit scrim covers the rest of the
/// screen, and a tap on the scrim or the back button closes it.
///
/// [builder] fills the whole screen: place the panel with a [Stack] and
/// [Positioned]; the empty space around it is the scrim. Taps there close the
/// panel unless [barrierDismissible] is false.
Future<T?> showPopupPanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = 'Close',
  Color barrierColor = AppScrim.color,
}) {
  return Navigator.of(context).push<T>(RawDialogRoute<T>(
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor,
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (ctx, animation, secondaryAnimation) => builder(ctx),
    transitionBuilder: (ctx, animation, secondaryAnimation, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  ));
}

/// A dialog that a tap outside does NOT close: only its own buttons do.
///
/// Only for steps where an accidental dismissal is dangerous: turning an
/// active SOS off, the crash "Are you OK?" countdown, a payment in progress.
/// The back button still behaves as usual for a dialog (it closes it with a
/// null result, which every caller treats as "keep things as they are").
Future<T?> showProtectedDialog<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showDialog<T>(
    context: context,
    // Protected: see above. An outside tap must never decide an SOS step.
    barrierDismissible: false,
    barrierColor: AppScrim.color,
    builder: builder,
  );
}
