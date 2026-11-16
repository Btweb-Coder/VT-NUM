import 'functions_service.dart';

class AuditService {
  AuditService({FunctionsService? functions}) : _functions = functions ?? FunctionsService();
  final FunctionsService _functions;

  Future<void> record(String action, {required bool success}) async {
    try {
      await _functions.call('record-operation', data: {
        'action': action,
        'outcome': success ? 'SUCCESS' : 'FAILURE',
      });
    } catch (_) {
      // Auditing must never hide the user-visible result of an operation.
    }
  }
}
