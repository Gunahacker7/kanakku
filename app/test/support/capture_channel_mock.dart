import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _captureChannel = MethodChannel('in.kanakku/capture');

/// Test double for the native capture channel, covering the full
/// v1.0 method set (v1.0.1: ported from the v0.9.1 fix's harness).
///
/// Stores read back empty and every write reports success — in
/// particular `setManual` returns true, which the v1.0.1 awaited
/// manual save requires: without a handler the channel answers
/// null, the save reads as failed, and the Add sheet rolls the
/// entry back out of the list.
void installCaptureChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_captureChannel, (call) async {
        switch (call.method) {
          case 'hasSmsPermission':
          case 'isNotificationAccessEnabled':
          case 'pinIsSet':
          case 'pinSet':
            return false;
          case 'pinVerify':
            // v1.0.4 counted-verify shape.
            return <String, Object>{'ok': false, 'lockoutSeconds': 0};
          case 'pinLockout':
            return 0;
          case 'encryptBackup':
          case 'decryptBackup':
            return null;
          case 'getRemoved':
          case 'getSplits':
          case 'getManual':
          case 'getStatement':
          case 'getCapturedSms':
          case 'getCapturedNotifications':
            return '[]';
          case 'readSmsInbox':
            return <Object?>[];
          case 'getBudgets':
          case 'getSettings':
          case 'getCategories':
            return '{}';
          // v1.1: the recurring + alert-state stores read back
          // EMPTY (never written) — the honest native behaviour on
          // a fresh install, so the migration seeding path runs.
          case 'getRecurring':
          case 'getAlertState':
            return '';
          case 'biometricStatus':
            return 'unsupportedApi';
          case 'setManual':
          case 'setRemoved':
          case 'setSplits':
          case 'setBudgets':
          case 'setStatement':
          case 'setSettings':
          case 'setCategories':
          case 'setRecurring':
          case 'setAlertState':
          case 'setDailySummary':
            return true;
          case 'shareCsv':
          case 'shareBytes':
            return '';
          case 'postSummaryNow':
          case 'postBudgetAlert':
          case 'biometricPrompt':
          case 'requestNotificationPermission':
          case 'requestSmsPermission':
          case 'openMail':
          case 'wipeAll':
            return false;
          default:
            return null;
        }
      });
}
