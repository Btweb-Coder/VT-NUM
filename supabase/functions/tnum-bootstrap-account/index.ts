
import { handler, json, requireUser } from "../_shared/common.ts";

Deno.serve(
  handler(async (req) => {
    const { admin, userId } = await requireUser(req);

    // The shared auth trigger should already have created the profile.
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select("user_id")
      .eq("user_id", userId)
      .maybeSingle();

    if (profileError) {
      throw profileError;
    }

    if (!profile) {
      throw new Error(
        "ACCOUNT_PROFILE_NOT_FOUND: The shared account profile has not been created.",
      );
    }

    // The existing account bootstrap should already have created the wallet.
    // Never create a second T-NUM-specific wallet.
    const { data: wallet, error: walletError } = await admin
      .from("wallets")
      .select("user_id, currency")
      .eq("user_id", userId)
      .maybeSingle();

    if (walletError) {
      throw walletError;
    }

    if (!wallet) {
      throw new Error(
        "ACCOUNT_WALLET_NOT_FOUND: The shared wallet has not been initialized.",
      );
    }

    return json({
      ready: true,
      walletCurrency: wallet.currency,
    });
  }),
);
