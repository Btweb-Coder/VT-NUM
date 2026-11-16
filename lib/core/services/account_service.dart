import 'functions_service.dart';

class AccountService {
  AccountService({FunctionsService? functions}) : _functions = functions ?? FunctionsService();
  final FunctionsService _functions;

  Future<void> bootstrap() => _functions.call('bootstrap-account');
}
