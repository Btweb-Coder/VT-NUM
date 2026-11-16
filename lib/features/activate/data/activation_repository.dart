import '../../../core/services/functions_service.dart';

class ActivationRepository {
  ActivationRepository({FunctionsService? functionsService})
    : _functions = functionsService ?? FunctionsService();

  final FunctionsService _functions;

  Future<Map<String, dynamic>> requestActivation({
    required String serviceId,
    required String countryId,
    required String idempotencyKey,
  }) async {
    return await _functions.call<Map<String, dynamic>>(
      'request-activation',
      data: {
        'serviceId': serviceId,
        'countryId': countryId,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<void> cancelActivation({required String orderId}) async {
    await _functions.call('cancel-activation', data: {'orderId': orderId});
  }

  Future<Map<String, dynamic>> getAnotherNumber({
    required String orderId,
    required String idempotencyKey,
  }) async {
    return await _functions.call<Map<String, dynamic>>(
      'replace-activation',
      data: {'orderId': orderId, 'idempotencyKey': idempotencyKey},
    );
  }
}
