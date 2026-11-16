export const VT_ACTIVATION_TIMEOUT_SECONDS = 360;

export type VtProviderActivationStatus = {
  ok: boolean;
  status: string;
  code?: string | null;
  raw?: string;
};

export type VtExpiryResult =
  | { outcome: "SKIPPED" }
  | { outcome: "RETRY"; reason: string }
  | { outcome: "SMS_RECEIVED"; code: string | null }
  | { outcome: "CANCELLED"; providerStatus: "CANCELLED" | "EXPIRED" };

export type VtExpiryDependencies = {
  claimCancellation: () => Promise<boolean>;
  canRequestCancellation: () => Promise<boolean>;
  getStatus: () => Promise<VtProviderActivationStatus>;
  requestCancellation: () => Promise<void>;
  recordSms: (code: string | null) => Promise<boolean>;
  finalizeCancellation: (
    providerStatus: "CANCELLED" | "EXPIRED",
  ) => Promise<boolean>;
  scheduleRetry: (reason: string) => Promise<void>;
};

/**
 * Processes a VT-NUM activation after its persisted application deadline.
 * Provider acceptance is never enough: only a subsequent exact-activation
 * status of CANCELLED or EXPIRED allows local finalization.
 */
export async function processVtActivationExpiry(
  dependencies: VtExpiryDependencies,
): Promise<VtExpiryResult> {
  if (!await dependencies.claimCancellation()) {
    return { outcome: "SKIPPED" };
  }

  let before: VtProviderActivationStatus;
  try {
    before = await dependencies.getStatus();
  } catch {
    return retry(dependencies, "STATUS_QUERY_FAILED");
  }

  const priorOutcome = await reconcileObservedStatus(before, dependencies);
  if (priorOutcome) return priorOutcome;

  if (!before.ok || before.status !== "WAITING") {
    return retry(dependencies, "PROVIDER_STATUS_UNCONFIRMED");
  }

  // The provider read is not a database lock. Recheck the persisted SMS and
  // financial state atomically immediately before issuing the close request.
  if (!await dependencies.canRequestCancellation()) {
    return retry(dependencies, "CANCELLATION_GUARD_REJECTED");
  }

  try {
    await dependencies.requestCancellation();
  } catch {
    // The request may have reached the server despite a client-side error.
    // Always query the exact activation before deciding what happens next.
  }

  let after: VtProviderActivationStatus;
  try {
    after = await dependencies.getStatus();
  } catch {
    return retry(dependencies, "POST_CANCELLATION_STATUS_FAILED");
  }

  const reconciled = await reconcileObservedStatus(after, dependencies);
  if (reconciled) return reconciled;
  return retry(dependencies, "CANCELLATION_NOT_CONFIRMED");
}

async function reconcileObservedStatus(
  provider: VtProviderActivationStatus,
  dependencies: VtExpiryDependencies,
): Promise<VtExpiryResult | null> {
  if (!provider.ok) return null;

  if (provider.status === "SMS_RECEIVED") {
    const code = provider.code?.trim() || null;
    const saved = await dependencies.recordSms(code);
    if (!saved) return retry(dependencies, "SMS_PERSISTENCE_NOT_CONFIRMED");
    return { outcome: "SMS_RECEIVED", code };
  }

  if (provider.status === "CANCELLED" || provider.status === "EXPIRED") {
    const terminalStatus = provider.status;
    const finalized = await dependencies.finalizeCancellation(terminalStatus);
    if (!finalized) return retry(dependencies, "CANCELLATION_FINALIZATION_NOT_CONFIRMED");
    return { outcome: "CANCELLED", providerStatus: terminalStatus };
  }

  return null;
}

async function retry(
  dependencies: VtExpiryDependencies,
  reason: string,
): Promise<VtExpiryResult> {
  await dependencies.scheduleRetry(reason);
  return { outcome: "RETRY", reason };
}
