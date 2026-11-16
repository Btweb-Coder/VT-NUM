import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_service.dart';
import 'audit_service.dart';

const String _authRedirectUrl = 'onlinesim://auth-callback';

class AuthService {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  // True only while signInWithPassword is being initiated manually by the user.
  bool _manualSignInInProgress = false;

  bool get isManualSignInInProgress => _manualSignInInProgress;

  Stream<AuthState> get authStateChanges =>
      _client.auth.onAuthStateChange;

  String? get currentEmail => _client.auth.currentUser?.email;

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    _manualSignInInProgress = true;

    try {
      final result = await _client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );

      // Keep account/wallet bootstrap exclusively on a successful manual sign-in.
      if (result.user?.emailConfirmedAt != null) {
        await AccountService().bootstrap();
      }

      await AuditService().record('SIGN_IN', success: true);
    } finally {
      _manualSignInInProgress = false;
    }
  }

  Future<void> register({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim();

    final response = await _client.auth.signUp(
      email: normalizedEmail,
      password: password,
      emailRedirectTo: _authRedirectUrl,
      data: {
        'terms_accepted': true,
        'terms_version': '2026-10-29',
      },
    );

    final user = response.user;

    if (user == null) {
      throw const AuthException('account_creation_incomplete');
    }

    // Supabase may return a user without identities when the email
    // is already registered, depending on the Auth configuration.
    final identities = user.identities;

    if (identities != null && identities.isEmpty) {
      throw const AuthException('email_already_registered');
    }

    await AuditService().record(
      'ACCOUNT_REGISTERED',
      success: true,
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<void> sendPasswordReset(String email) {
    return _client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: _authRedirectUrl,
    );
  }

  Future<void> updatePassword(String newPassword) async {
    await _client.auth.updateUser(
      UserAttributes(password: newPassword),
    );
  }

  Future<void> resendVerification() async {
    final user = _client.auth.currentUser;

    if (user == null) return;

    await _client.auth.resend(
      type: OtpType.signup,
      email: user.email!,
    );

    await AuditService().record(
      'EMAIL_VERIFICATION_RESENT',
      success: true,
    );
  }

  Future<bool> refreshVerification() async {
    final response = await _client.auth.getUser();
    return response.user?.emailConfirmedAt != null;
  }
}
