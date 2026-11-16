import {
  admin,
  ApiError,
  authenticatedUser,
  body,
  handle,
  json,
  requiredString,
} from '../_shared/core.ts';
import {
  buyRental,
  cancelRental,
  extendRental,
  getRentalCatalog,
  getRentalExtensionOptions,
  getRentalStatus,
  ProxnumRentalError,
} from '../_shared/proxnum_rentals.ts';

type Row = Record<string, any>;
const RENTAL_LOG = '[PROXNUM-RENTALS]';

function logRental(
  step: string,
  details: Record<string, unknown> = {},
) {
  console.log(RENTAL_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}

function logRentalError(
  step: string,
  details: Record<string, unknown> = {},
) {
  console.error(RENTAL_LOG, {
    timestamp: new Date().toISOString(),
    step,
    ...details,
  });
}
async function provider(db: ReturnType<typeof admin>) {
  const { data, error } = await db.from('providers').select('id,slug,endpoint,config').eq(
    'slug',
    'proxnum',
  ).eq('active', true).single();
  if (error || !data || (data.config?.features?.rental_numbers !== true)) {
    throw new ApiError(503, 'RENTALS_NOT_ENABLED');
  }
  return data;
}
const safeError = (e: unknown) =>
  e instanceof ProxnumRentalError
    ? e
    : new ProxnumRentalError('Provider unavailable', 'PROVIDER_UNAVAILABLE');

Deno.serve(handle(async (request) => {
  const user = await authenticatedUser(request);
  const data = await body(request);
  const action = requiredString(data, 'action');
    logRental('REQUEST_RECEIVED', {
    action,
    userId: user.id,
  });
  const db = admin();
  const p = await provider(db);
  if (action === 'catalog') {
    const catalog = await getRentalCatalog(
      p,
      typeof data.country === 'string' ? data.country : undefined,
      typeof data.hours === 'number' ? data.hours : undefined,
    );
        console.log('[PROXNUM EDGE] Action catalogue reçue :', {
      country: typeof data.country === 'string' ? data.country : null,
      hours: typeof data.hours === 'number' ? data.hours : null,
    });

    console.log('[PROXNUM EDGE] Catalogue reçu du module :', {
      countriesCount: catalog.countries.length,
      countries: catalog.countries,
      durationsCount: catalog.durations.length,
      servicesCount: catalog.services.length,
    });
    const { data: rule, error: ruleError } = await db.from('pricing_rules').select(
      'markup_type,markup_value',
    ).eq('active', true).single();
    if (ruleError || !rule) throw new ApiError(503, 'PRICING_RULE_NOT_CONFIGURED');
    return json({
      success: true,
      catalog: {
        ...catalog,
       services: catalog.services.map((s) => {
  const { price, ...publicService } = s;

  const customerPrice = Number(
    (
      rule.markup_type === 'percentage'
        ? price * (1 + Number(rule.markup_value) / 100)
        : price + Number(rule.markup_value)
    ).toFixed(6),
  );

  return {
    ...publicService,
    customerPrice,
  };
}),
      },
    });
  }
  if (action === 'buy') {
    const key = requiredString(data, 'idempotencyKey'),
      service = requiredString(data, 'service'),
      country = requiredString(data, 'country');
    const hours = data.hours;
    if (!Number.isInteger(hours) || Number(hours) <= 0) throw new ApiError(400, 'INVALID_HOURS');
    const expectedCustomerPrice = Number(data.expectedCustomerPrice);
    if (!Number.isFinite(expectedCustomerPrice) || expectedCustomerPrice <= 0) {
      throw new ApiError(400, 'INVALID_EXPECTED_PRICE');
    }
        logRental('BUY_STARTED', {
      userId: user.id,
      service,
      country,
      hours,
      expectedCustomerPrice,
    });
    const catalog = await getRentalCatalog(p, country, Number(hours));
    if (!catalog.durations.some((x) => x.hours === hours)) throw new ApiError(409, 'OFFER_CHANGED');
    const offer = catalog.services.find((x) => x.code === service);
    if (!offer || !offer.stock || offer.stock < 1) throw new ApiError(409, 'NO_NUMBERS');
    const { data: reserved, error } = await db.rpc('reserve_proxnum_rental', {
      p_user_id: user.id,
      p_key: key,
      p_service_code: offer.code,
      p_service_name: offer.name,
      p_country_code: country,
      p_country_name: catalog.countries.find((x) => x.id === country)?.name ?? country,
      p_hours: hours,
      p_provider_price: offer.price,
    }).single();
    if (error) {
      throw new ApiError(error.message.includes('INSUFFICIENT_BALANCE') ? 402 : 409, error.message);
    }
    const r = reserved as Row;
        logRental('BUY_FUNDS_RESERVED', {
      rentalId: r.rental_id,
      status: r.status,
      isNew: r.is_new,
    });
    if (r.is_new !== true) {
      return json({
        success: r.status === 'ACTIVE',
        rentalId: r.rental_id,
        status: r.status,
        reused: true,
      }, r.status === 'FAILED' ? 409 : r.status === 'ACTIVE' ? 200 : 202);
    }
    if (
      Math.round(Number(r.customer_price) * 1_000_000) !==
        Math.round(expectedCustomerPrice * 1_000_000)
    ) {
      const { error: releaseError } = await db.rpc('finish_proxnum_rental_hold', {
        p_rental_id: r.rental_id,
        p_operation_key: `PURCHASE:${key}`,
        p_capture: false,
      });
      await db.from('proxnum_rentals').update({
        status: releaseError ? 'RECONCILIATION_REQUIRED' : 'FAILED',
        failure_code: 'CUSTOMER_PRICE_CHANGED',
      }).eq('id', r.rental_id);
      await db.from('proxnum_rental_operations').update({
        status: releaseError ? 'RECONCILIATION_REQUIRED' : 'FAILED',
        error_code: 'CUSTOMER_PRICE_CHANGED',
      }).eq('rental_id', r.rental_id).eq('operation', 'PURCHASE').eq('idempotency_key', key);
      throw new ApiError(
        releaseError ? 202 : 409,
        releaseError ? 'RECONCILIATION_REQUIRED' : 'CUSTOMER_PRICE_CHANGED',
      );
    }
    let providerBuyConfirmed = false;
   try {
        logRental('BUY_PROVIDER_CALL_STARTED', {
      rentalId: r.rental_id,
      service,
      country,
      hours: Number(hours),
      providerPrice: offer.price,
    });
const bought = await buyRental(
p,
service,
country,
Number(hours),
offer.price,
);
    logRental('BUY_PROVIDER_RESPONSE', {
      rentalId: r.rental_id,
      hasRentalId: Boolean(bought.rentalId),
      hasPhone: Boolean(bought.phone),
      hasExpiry: Boolean(bought.expiresAt),
    });
providerBuyConfirmed = true;
const providerRentalId = String(bought.rentalId ?? '').trim();
if (!providerRentalId) {
throw new ProxnumRentalError(
'Provider purchase returned no rental ID; manual reconciliation required',
'PROVIDER_RESULT_UNCERTAIN',
undefined,
true,
);
}

const { error: initialSaveError } = await db
.from('proxnum_rentals')
.update({
provider_rental_id: providerRentalId,
phone_number: bought.phone ?? null,
provider_price: bought.providerPrice ?? null,
status: 'PURCHASE_REQUESTED',
purchased_at: bought.purchasedAt || new Date().toISOString(),
})
.eq('id', r.rental_id);
if (initialSaveError) {
throw new ProxnumRentalError(
'Provider purchase may have succeeded, but its ID could not be persisted; manual reconciliation required',
'PROVIDER_RESULT_UNCERTAIN',
undefined,
true,
);
}

const confirmed = await getRentalStatus(p, providerRentalId);
logRental('BUY_PROVIDER_CONFIRMATION', {
  rentalId: r.rental_id,
  providerStatus: confirmed.status,
  hasPhone: Boolean(confirmed.phone || bought.phone),
  hasExpiry: Boolean(confirmed.expiresAt || bought.expiresAt),
});
const confirmedPhone = confirmed.phone || bought.phone;
const confirmedExpiry = confirmed.expiresAt || bought.expiresAt;
if (
confirmed.status !== 'active' ||
!confirmedPhone ||
!confirmedExpiry ||
(confirmed.phone && bought.phone &&
confirmed.phone !== bought.phone)
) {
  throw new ProxnumRentalError(
'Provider purchase confirmation is incomplete; reserved funds retained for reconciliation',
'PROVIDER_RESULT_UNCERTAIN',
undefined,
true,
);
}
const { error: saveError } = await db
.from('proxnum_rentals')
.update({
provider_rental_id: providerRentalId,
phone_number: confirmedPhone,
provider_price: bought.providerPrice ?? null,
status: 'ACTIVE',
purchased_at: bought.purchasedAt || new Date().toISOString(),
expires_at: confirmedExpiry,
cancel_until: bought.cancelUntil ?? null,
can_cancel: confirmed.canCancel,
can_extend: confirmed.canExtend,
last_provider_status: confirmed.status,
last_provider_payload: confirmed,
last_sync_at: new Date().toISOString(),
sync_failures: 0,
last_sync_error: null,
})
.eq('id', r.rental_id);
if (saveError) {
throw new ProxnumRentalError(
'Rental confirmation could not be persisted; reserved funds retained for reconciliation',
'PROVIDER_RESULT_UNCERTAIN',
undefined,
true,
);
}
const { error: holdError } = await db.rpc(
'finish_proxnum_rental_hold',
{
p_rental_id: r.rental_id,
p_operation_key: `PURCHASE:${key}`,
p_capture: true,
},
);
if (holdError) {
        throw new ProxnumRentalError(
          'Wallet capture failed; reconciliation required',
          'PROVIDER_RESULT_UNCERTAIN',
          undefined,
          true,
        );
      }
const { error: operationUpdateError } = await db
  .from('proxnum_rental_operations')
  .update({
    status: 'SUCCEEDED',
    amount: bought.providerPrice ?? null,
    provider_payload: bought,
    error_code: null,
  })
  .eq('rental_id', r.rental_id)
  .eq('operation', 'PURCHASE')
  .eq('idempotency_key', key);

if (operationUpdateError) {
  console.error('Purchase operation finalization failed', {
    rentalId: r.rental_id,
    operationUpdateError,
  });

  await db.from('proxnum_rentals').update({
    status: 'RECONCILIATION_REQUIRED',
    last_sync_error: 'PURCHASE_OPERATION_FINALIZATION_FAILED',
  }).eq('id', r.rental_id);

  return json({
    success: false,
    rentalId: r.rental_id,
    status: 'RECONCILIATION_REQUIRED',
    message: 'Location confirmée ; rapprochement comptable nécessaire.',
  }, 202);
}

return json({
  success: true,
  rentalId: r.rental_id,
  status: 'ACTIVE',
});
    } catch (e) {
      const err = safeError(e);
      logRentalError('BUY_FAILED_OR_UNCERTAIN', {
  rentalId: r?.rental_id ?? null,
  errorCode: err.code,
  httpStatus: err.httpStatus,
  outcomeUncertain: err.outcomeUncertain,
  providerBuyConfirmed,
});
      const mayReleaseHold =
        !providerBuyConfirmed &&
        !err.outcomeUncertain &&
        err.httpStatus !== undefined &&
        err.httpStatus < 500;
if (mayReleaseHold) {
const { error: releaseError } = await db.rpc(
'finish_proxnum_rental_hold',
{
p_rental_id: r.rental_id,
p_operation_key: `PURCHASE:${key}`,
p_capture: false,
},
);
if (releaseError) {
          await db.from('proxnum_rentals').update({
            status: 'RECONCILIATION_REQUIRED',
            failure_code: 'WALLET_RELEASE_FAILED',
          }).eq('id', r.rental_id);
await db.from('proxnum_rental_operations').update({
            status: 'RECONCILIATION_REQUIRED',
            error_code: 'WALLET_RELEASE_FAILED',
          })
            .eq('rental_id', r.rental_id)
            .eq('operation', 'PURCHASE')
            .eq('idempotency_key', key);
throw new ApiError(202, 'RECONCILIATION_REQUIRED');
        }
await db.from('proxnum_rentals').update({
          status: 'FAILED',
          failure_code: err.code,
        }).eq('id', r.rental_id);
await db.from('proxnum_rental_operations').update({
          status: 'FAILED',
          error_code: err.code,
        })
          .eq('rental_id', r.rental_id)
          .eq('operation', 'PURCHASE')
          .eq('idempotency_key', key);
      } else {
        await db.from('proxnum_rentals').update({
          status: 'RECONCILIATION_REQUIRED',
          failure_code: err.code,
        }).eq('id', r.rental_id);
await db.from('proxnum_rental_operations').update({
          status: 'RECONCILIATION_REQUIRED',
          error_code: err.code,
        })
          .eq('rental_id', r.rental_id)
          .eq('operation', 'PURCHASE')
          .eq('idempotency_key', key);
      }
throw new ApiError(
        mayReleaseHold ? (err.httpStatus ?? 503) : 202,
        mayReleaseHold ? err.code : 'RECONCILIATION_REQUIRED',
      );
    } 
  }
  const rentalId = requiredString(data, 'rentalId');
  const { data: rental, error } = await db.from('proxnum_rentals').select('*').eq('id', rentalId)
    .eq('user_id', user.id).single();
  if (error || !rental) throw new ApiError(404, 'RENTAL_NOT_FOUND');
  if (action === 'status') {
    if (!rental.provider_rental_id) {
      return json({ success: false, status: rental.status, sync: 'RECONCILIATION_REQUIRED' }, 202);
    }
    const s = await getRentalStatus(p, rental.provider_rental_id);
    // Un statut fournisseur ordinaire ne doit jamais effacer un rapprochement financier.
    // Une annulation n'est considérée comme confirmée que si Proxnum renvoie explicitement cancelled.
    const isFinancialReconciliation = rental.status === 'RECONCILIATION_REQUIRED';
    const providerConfirmedCancelled = s.status === 'cancelled';
    const providerLocalStatus = s.status === 'active'
      ? 'ACTIVE'
      : s.status === 'cancelling'
      ? 'CANCEL_PENDING'
      : s.status === 'cancelled'
      ? 'CANCELLED'
      : s.status === 'expired'
      ? 'EXPIRED'
      : rental.status;
    const localStatus = isFinancialReconciliation && !providerConfirmedCancelled
      ? 'RECONCILIATION_REQUIRED'
      : providerLocalStatus;
    const syncTime = new Date();

    const { error: syncUpdateError } = await db
      .from('proxnum_rentals')
      .update({
        status: localStatus,
        expires_at: s.expiresAt,
        can_cancel: s.canCancel,
        can_extend: s.canExtend,
        cancel_pending: s.cancelPending,
        last_provider_status: s.status,
        last_provider_payload: s,
        last_sync_at: syncTime.toISOString(),
        next_sync_at: new Date(syncTime.getTime() + 10000).toISOString(),
        sync_failures: 0,
        last_sync_error: isFinancialReconciliation && !providerConfirmedCancelled
          ? (rental.last_sync_error ?? 'RECONCILIATION_REQUIRED')
          : null,
      })
      .eq('id', rental.id);

    if (syncUpdateError) {
      console.error('Failed to persist rental status sync', {
        rentalId: rental.id,
        providerStatus: s.status,
        error: syncUpdateError,
      });
      return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'RENTAL_SYNC_PERSIST_FAILED' }, 202);
    }

    for (const m of s.messages) {
      const { error: messageError } = await db.from('proxnum_rental_messages').upsert({
        rental_id: rental.id,
        provider_message_id: String(m.id),
        sender: m.sender ?? null,
        message_text: m.text,
        sms_code: m.code ?? null,
        message_at: m.date ?? null,
      }, { onConflict: 'rental_id,provider_message_id', ignoreDuplicates: true });
      if (messageError) {
        console.error('Failed to persist provider rental message', { rentalId: rental.id, error: messageError });
      }
    }

    if (s.status === 'cancelled') {
      const { error: refundError } = await db.rpc('refund_confirmed_proxnum_rental', {
        p_rental_id: rental.id,
      });
      if (refundError) {
        const { error: rentalUpdateError } = await db.from('proxnum_rentals').update({
          status: 'RECONCILIATION_REQUIRED',
          last_sync_error: 'REFUND_RECONCILIATION_REQUIRED',
        }).eq('id', rental.id);
        const { error: operationUpdateError } = await db.from('proxnum_rental_operations').update({
          status: 'RECONCILIATION_REQUIRED',
          error_code: 'REFUND_RECONCILIATION_REQUIRED',
          provider_payload: s,
        }).eq('rental_id', rental.id).eq('operation', 'CANCEL').in('status', [
          'STARTED', 'PENDING', 'RECONCILIATION_REQUIRED',
        ]);
        if (rentalUpdateError || operationUpdateError) {
          console.error('Failed to persist refund reconciliation state after status sync', {
            rentalId: rental.id, rentalUpdateError, operationUpdateError,
          });
        }
        return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'REFUND_RECONCILIATION_REQUIRED' }, 202);
      }
      const { error: operationUpdateError } = await db.from('proxnum_rental_operations').update({
        status: 'SUCCEEDED',
        provider_payload: s,
      }).eq('rental_id', rental.id).eq('operation', 'CANCEL').in('status', [
        'STARTED', 'PENDING', 'RECONCILIATION_REQUIRED',
      ]);
      if (operationUpdateError) {
        const { error: rentalUpdateError } = await db.from('proxnum_rentals').update({
          status: 'RECONCILIATION_REQUIRED',
          last_sync_error: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND',
        }).eq('id', rental.id);
        console.error('Refund may have succeeded but cancellation operation finalization failed', {
          rentalId: rental.id, operationUpdateError, rentalUpdateError,
        });
        return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND' }, 202);
      }
    }

    if (s.status === 'active' && rental.status === 'CANCEL_PENDING') {
      const { error: operationUpdateError } = await db.from('proxnum_rental_operations').update({
        status: 'FAILED',
        error_code: 'CANCEL_REJECTED',
        provider_payload: s,
      }).eq('rental_id', rental.id).eq('operation', 'CANCEL').in('status', [
        'PENDING', 'RECONCILIATION_REQUIRED',
      ]);
      if (operationUpdateError) console.error('Failed to persist rejected cancellation', { rentalId: rental.id, operationUpdateError });
    }
    return json({ success: true, status: s.status, messages: s.messages });
  }
  if (action === 'extend-options') {
    if (!rental.provider_rental_id || rental.status !== 'ACTIVE') {
      throw new ApiError(409, 'RENTAL_NOT_ACTIVE');
    }
    const live = await getRentalStatus(p, rental.provider_rental_id);
    if (live.status !== 'active' || live.canExtend !== true) {
      throw new ApiError(409, 'EXTENSION_NOT_ALLOWED');
    }
    const [options, { data: rule, error: ruleError }] = await Promise.all([
      getRentalExtensionOptions(p, rental.provider_rental_id),
      db.from('pricing_rules').select('markup_type,markup_value').eq('active', true).single(),
    ]);
    if (ruleError || !rule) throw new ApiError(503, 'PRICING_RULE_NOT_CONFIGURED');
    return json({
      success: true,
     options: options.map((o: { hours: number; price: number; label?: string }) => {
  const { price, ...publicOption } = o;

  const customerPrice = Number(
    (
      rule.markup_type === 'percentage'
        ? price * (1 + Number(rule.markup_value) / 100)
        : price + Number(rule.markup_value)
    ).toFixed(6),
  );

  return {
    ...publicOption,
    customerPrice,
  };
}),
    });
  }
  if (action === 'extend') {
    const key = requiredString(data, 'idempotencyKey'), hours = data.hours;
    if (!Number.isInteger(hours) || Number(hours) <= 0) throw new ApiError(400, 'INVALID_HOURS');
    const expectedCustomerPrice = Number(data.expectedCustomerPrice);
    if (!Number.isFinite(expectedCustomerPrice) || expectedCustomerPrice <= 0) {
      throw new ApiError(400, 'INVALID_EXPECTED_PRICE');
    }
    const { data: prior, error: priorError } = await db.from('proxnum_rental_renewals').select(
      'id,rental_id,requested_hours,status,new_expires_at',
    ).eq('user_id', user.id).eq('idempotency_key', key).maybeSingle();
    if (priorError) throw priorError;
    if (prior) {
      if (prior.rental_id !== rental.id || prior.requested_hours !== hours) {
        throw new ApiError(409, 'IDEMPOTENCY_KEY_REUSED');
      }
      return json({
        success: prior.status === 'SUCCEEDED',
        renewalId: prior.id,
        status: prior.status,
        expiresAt: prior.new_expires_at,
        reused: true,
      }, prior.status === 'SUCCEEDED' ? 200 : prior.status === 'FAILED' ? 409 : 202);
    }
    if (!rental.provider_rental_id || rental.status !== 'ACTIVE') {
      throw new ApiError(409, 'RENTAL_NOT_ACTIVE');
    }
    const live = await getRentalStatus(p, rental.provider_rental_id);
    if (live.status !== 'active' || live.canExtend !== true) {
      throw new ApiError(409, 'EXTENSION_NOT_ALLOWED');
    }
    await db.from('proxnum_rentals').update({
      can_extend: true,
      last_provider_status: live.status,
      last_provider_payload: live,
    }).eq('id', rental.id);
    const options = await getRentalExtensionOptions(p, rental.provider_rental_id);
    const offer = options.find((x) => x.hours === hours);
    if (!offer) throw new ApiError(409, 'OFFER_CHANGED');
    const { data: reserved, error: reserveError } = await db.rpc('reserve_proxnum_rental_renewal', {
      p_user_id: user.id,
      p_rental_id: rental.id,
      p_key: key,
      p_hours: hours,
      p_provider_price: offer.price,
    }).single();
    if (reserveError) {
      throw new ApiError(
        reserveError.message.includes('INSUFFICIENT_BALANCE') ? 402 : 409,
        reserveError.message,
      );
    }
    const n = reserved as Row;
    if (n.is_new !== true) {
      return json({
        success: n.status === 'SUCCEEDED',
        renewalId: n.renewal_id,
        status: n.status,
        reused: true,
      }, n.status === 'FAILED' ? 409 : n.status === 'SUCCEEDED' ? 200 : 202);
    }
    if (
      Math.round(Number(n.customer_price) * 1_000_000) !==
        Math.round(expectedCustomerPrice * 1_000_000)
    ) {
      const { error: releaseError } = await db.rpc('finish_proxnum_rental_hold', {
        p_rental_id: rental.id,
        p_operation_key: `RENEWAL:${key}`,
        p_capture: false,
      });
      await db.from('proxnum_rental_renewals').update({
        status: releaseError ? 'RECONCILIATION_REQUIRED' : 'FAILED',
        failure_code: 'CUSTOMER_PRICE_CHANGED',
      }).eq('id', n.renewal_id);
      await db.from('proxnum_rentals').update({
        status: releaseError ? 'RENEWAL_REQUESTED' : 'ACTIVE',
      }).eq('id', rental.id);
      throw new ApiError(
        releaseError ? 202 : 409,
        releaseError ? 'RECONCILIATION_REQUIRED' : 'CUSTOMER_PRICE_CHANGED',
      );
    }
    let providerCallStarted = false;

try {
  // À partir de cet instant, une erreur réseau peut laisser
  // le résultat fournisseur incertain.
  providerCallStarted = true;

  const changed = await extendRental(
    p,
    rental.provider_rental_id,
    Number(hours),
    offer.price,
  );

  const confirmed = await getRentalStatus(
    p,
    rental.provider_rental_id,
  );

 const confirmedExpiryMs = typeof confirmed.expiresAt === 'string'
  ? Date.parse(confirmed.expiresAt)
  : NaN;

const changedExpiryMs = typeof changed.expiresAt === 'string'
  ? Date.parse(changed.expiresAt)
  : NaN;

if (
  confirmed.status !== 'active' ||
  !Number.isFinite(confirmedExpiryMs) ||
  !Number.isFinite(changedExpiryMs) ||
  confirmedExpiryMs !== changedExpiryMs
) {
  throw new ProxnumRentalError(
    'Renewal confirmation incomplete',
    'PROVIDER_RESULT_UNCERTAIN',
    undefined,
    true,
  );
}

  const { error: finalizeError } = await db.rpc(
    'finalize_proxnum_rental_renewal',
    {
      p_rental_id: rental.id,
      p_renewal_id: n.renewal_id,
      p_expires_at: confirmed.expiresAt,
      p_provider_payload: changed,
      p_can_extend: confirmed.canExtend,
      p_provider_status: confirmed.status,
      p_status_payload: confirmed,
    },
  );

  if (finalizeError) {
    throw new ProxnumRentalError(
      'Renewal finalization failed; reconciliation required',
      'PROVIDER_RESULT_UNCERTAIN',
      undefined,
      true,
    );
  }

  return json({
    success: true,
    renewalId: n.renewal_id,
    status: 'SUCCEEDED',
    expiresAt: confirmed.expiresAt,
  });
} catch (e) {
  const err = safeError(e);

  // Ne jamais libérer automatiquement les fonds après le début
  // de l'appel fournisseur si son résultat n'est pas prouvé.
  if (
    providerCallStarted ||
    err.outcomeUncertain ||
    err.httpStatus === undefined ||
    err.httpStatus >= 500
  ) {
    await db.from('proxnum_rental_renewals').update({
      status: 'RECONCILIATION_REQUIRED',
      failure_code: err.code,
    }).eq('id', n.renewal_id);

    await db.from('proxnum_rentals').update({
      status: 'RECONCILIATION_REQUIRED',
      last_sync_error: err.code,
    }).eq('id', rental.id);

    return json({
      success: false,
      renewalId: n.renewal_id,
      status: 'RECONCILIATION_REQUIRED',
      message:
        'Le résultat fournisseur doit être vérifié. Les fonds restent réservés.',
    }, 202);
  }

  // Seul un échec survenu avant tout appel fournisseur peut
  // suivre le chemin de libération automatique.
  const { error: releaseError } = await db.rpc(
    'finish_proxnum_rental_hold',
    {
      p_rental_id: rental.id,
      p_operation_key: `RENEWAL:${key}`,
      p_capture: false,
    },
  );

  if (releaseError) {
    await db.from('proxnum_rental_renewals').update({
      status: 'RECONCILIATION_REQUIRED',
      failure_code: 'WALLET_RELEASE_FAILED',
    }).eq('id', n.renewal_id);

    await db.from('proxnum_rentals').update({
      status: 'RECONCILIATION_REQUIRED',
      last_sync_error: 'WALLET_RELEASE_FAILED',
    }).eq('id', rental.id);

    return json({
      success: false,
      renewalId: n.renewal_id,
      status: 'RECONCILIATION_REQUIRED',
    }, 202);
  }

  await db.from('proxnum_rental_renewals').update({
    status: 'FAILED',
    failure_code: err.code,
  }).eq('id', n.renewal_id);

  await db.from('proxnum_rentals').update({
    status: 'ACTIVE',
  }).eq('id', rental.id);

  throw new ApiError(err.httpStatus ?? 503, err.code);
}
  }
  if (action === 'cancel') {
    const key = requiredString(data, 'idempotencyKey');
        logRental('CANCEL_STARTED', {
      rentalId: rental.id,
      hasProviderRentalId: Boolean(rental.provider_rental_id),
      currentStatus: rental.status,
    });
    if (!rental.provider_rental_id) throw new ApiError(409, 'RENTAL_NOT_ACTIVE');
    let operation: Row | undefined;
    const { data: old, error: oldError } = await db.from('proxnum_rental_operations').select('*')
      .eq('user_id', user.id).eq('operation', 'CANCEL').eq('idempotency_key', key).maybeSingle();
    if (oldError) throw oldError;
    if (old) {
            
      if (old.status === 'SUCCEEDED' || old.status === 'FAILED') {
        return json(
          { success: old.status === 'SUCCEEDED', status: old.status, reused: true },
          old.status === 'FAILED' ? 409 : 200,
        );
      }
      operation = old;
      const live = await getRentalStatus(p, rental.provider_rental_id);
      if (live.status === 'cancelled') {
        const { error: confirmedSaveError } = await db.from('proxnum_rentals').update({
          status: 'CANCELLED',
          cancel_pending: false,
          last_provider_status: live.status,
          last_provider_payload: live,
        }).eq('id', rental.id);
        if (confirmedSaveError) {
          const { error: rentalReconcileError } = await db.from('proxnum_rentals').update({
            status: 'RECONCILIATION_REQUIRED',
            last_sync_error: 'CANCEL_CONFIRMATION_PERSIST_FAILED',
          }).eq('id', rental.id);
          const { error: operationReconcileError } = await db.from('proxnum_rental_operations').update({
            status: 'RECONCILIATION_REQUIRED',
            error_code: 'CANCEL_CONFIRMATION_PERSIST_FAILED',
            provider_payload: live,
          }).eq('id', old.id);
          console.error('Provider cancellation is confirmed but local status could not be saved', { rentalId: rental.id, confirmedSaveError, rentalReconcileError, operationReconcileError });
          return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'CANCEL_CONFIRMATION_PERSIST_FAILED' }, 202);
        }
        const { error: refundError } = await db.rpc('refund_confirmed_proxnum_rental', {
          p_rental_id: rental.id,
        });
        if (refundError) {
          const { error: operationUpdateError } = await db
            .from('proxnum_rental_operations')
            .update({
              status: 'RECONCILIATION_REQUIRED',
              error_code: 'REFUND_RECONCILIATION_REQUIRED',
              provider_payload: live,
            })
            .eq('id', old.id);

          const { error: rentalUpdateError } = await db
            .from('proxnum_rentals')
            .update({
              status: 'RECONCILIATION_REQUIRED',
              last_sync_error: 'REFUND_RECONCILIATION_REQUIRED',
            })
            .eq('id', rental.id);

          if (operationUpdateError || rentalUpdateError) {
            console.error('Failed to persist refund reconciliation state', {
              rentalId: rental.id,
              operationId: old.id,
              operationUpdateError,
              rentalUpdateError,
            });
          }

          return json({
            success: false,
            status: 'RECONCILIATION_REQUIRED',
            reason: 'REFUND_RECONCILIATION_REQUIRED',
          }, 202);
        }
        const { error: operationFinalizeError } = await db.from('proxnum_rental_operations').update({
          status: 'SUCCEEDED',
          error_code: null,
          provider_payload: live,
        }).eq('id', old.id);
        if (operationFinalizeError) {
          const { error: rentalReconcileError } = await db.from('proxnum_rentals').update({
            status: 'RECONCILIATION_REQUIRED',
            last_sync_error: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND',
          }).eq('id', rental.id);
          console.error('Refund may have succeeded but cancellation operation finalization failed', { rentalId: rental.id, operationId: old.id, operationFinalizeError, rentalReconcileError });
          return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND' }, 202);
        }
        return json({ success: true, status: 'CANCELLED', reused: true });
      }
      if (live.status === 'cancelling' || live.cancelPending === true) {
        await db.from('proxnum_rentals').update({
          status: 'CANCEL_PENDING',
          cancel_pending: true,
          last_provider_status: live.status,
          last_provider_payload: live,
        }).eq('id', rental.id);
        await db.from('proxnum_rental_operations').update({
          status: 'PENDING',
          provider_payload: live,
        }).eq('id', old.id);
        return json({ success: false, status: 'CANCEL_PENDING', reused: true }, 202);
      }
      if (live.status !== 'active' || live.canCancel !== true || live.messages.length > 0) {
        const localStatus = live.status === 'expired'
          ? 'EXPIRED'
          : live.status === 'cancelled'
          ? 'CANCELLED'
          : 'ACTIVE';
        await db.from('proxnum_rentals').update({
          status: localStatus,
          cancel_pending: false,
          can_cancel: live.canCancel,
          last_provider_status: live.status,
          last_provider_payload: live,
        }).eq('id', rental.id);
        await db.from('proxnum_rental_operations').update({
          status: 'FAILED',
          error_code: 'CANCEL_NOT_ALLOWED',
          provider_payload: live,
        }).eq('id', old.id);
        return json({ success: false, status: 'FAILED', reused: true }, 409);
      }
      await db.from('proxnum_rental_operations').update({
        status: 'FAILED',
        provider_payload: live,
        error_code: 'PREVIOUS_CANCEL_NOT_CONFIRMED',
      }).eq('id', old.id);
      await db.from('proxnum_rentals').update({
        status: 'ACTIVE',
        cancel_pending: false,
        can_cancel: live.canCancel,
        last_provider_status: live.status,
        last_provider_payload: live,
      }).eq('id', rental.id);
      return json({ success: false, status: 'FAILED', reused: true, retryWithNewKey: true }, 409);
    } else {
      if (rental.status !== 'ACTIVE' || rental.can_cancel !== true) {
        throw new ApiError(409, 'CANCEL_NOT_ALLOWED');
      }
      const live = await getRentalStatus(p, rental.provider_rental_id);
      if (
        live.status !== 'active' || live.canCancel !== true || live.cancelPending === true ||
        live.messages.length > 0
      ) throw new ApiError(409, 'CANCEL_NOT_ALLOWED');
      const { data: created, error: createError } = await db.from('proxnum_rental_operations')
        .insert({
          rental_id: rental.id,
          user_id: user.id,
          operation: 'CANCEL',
          idempotency_key: key,
          status: 'STARTED',
          provider_payload: live,
        }).select('*').single();
      if (createError) {
        const { data: raced } = await db.from('proxnum_rental_operations').select('*').eq(
          'user_id',
          user.id,
        ).eq('operation', 'CANCEL').eq('idempotency_key', key).maybeSingle();
        if (raced?.rental_id !== rental.id) throw new ApiError(409, 'IDEMPOTENCY_KEY_REUSED');
        return json({
          success: false,
          status: raced?.status ?? 'RECONCILIATION_REQUIRED',
          reused: true,
        }, 202);
      }
      operation = created;
    }
    try {
            logRental('CANCEL_PROVIDER_CALL_STARTED', {
        rentalId: rental.id,
        operationId: operation!.id,
      });
      const result = await cancelRental(p, rental.provider_rental_id);
            logRental('CANCEL_PROVIDER_RESPONSE', {
        rentalId: rental.id,
        operationId: operation!.id,
        pending: result.pending,
      });
      await db.from('proxnum_rental_operations').update({
        status: result.pending ? 'PENDING' : 'RECONCILIATION_REQUIRED',
        provider_payload: result,
      }).eq('id', operation!.id);
      await db.from('proxnum_rentals').update({
        status: result.pending ? 'CANCEL_PENDING' : 'CANCEL_REQUESTED',
        cancel_pending: result.pending,
      }).eq('id', rental.id);
      let finalStatus = result.pending ? 'CANCEL_PENDING' : 'CANCEL_REQUESTED';
      if (!result.pending) {
        const confirmed = await getRentalStatus(p, rental.provider_rental_id);
        if (confirmed.status === 'cancelled') {
          finalStatus = 'CANCELLED';
          const { error: confirmedSaveError } = await db.from('proxnum_rentals').update({
            status: 'CANCELLED',
            cancel_pending: false,
            last_provider_status: 'cancelled',
            last_provider_payload: confirmed,
          }).eq('id', rental.id);
          if (confirmedSaveError) {
            const { error: rentalReconcileError } = await db.from('proxnum_rentals').update({
              status: 'RECONCILIATION_REQUIRED',
              last_sync_error: 'CANCEL_CONFIRMATION_PERSIST_FAILED',
            }).eq('id', rental.id);
            const { error: operationReconcileError } = await db.from('proxnum_rental_operations').update({
              status: 'RECONCILIATION_REQUIRED',
              error_code: 'CANCEL_CONFIRMATION_PERSIST_FAILED',
              provider_payload: confirmed,
            }).eq('id', operation!.id);
            console.error('Provider cancellation is confirmed but local status could not be saved', { rentalId: rental.id, confirmedSaveError, rentalReconcileError, operationReconcileError });
            return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'CANCEL_CONFIRMATION_PERSIST_FAILED' }, 202);
          }
          const { error: refundError } = await db.rpc('refund_confirmed_proxnum_rental', {
            p_rental_id: rental.id,
          });
         if (refundError) {
  const { error: operationUpdateError } = await db
    .from('proxnum_rental_operations')
    .update({
      status: 'RECONCILIATION_REQUIRED',
      error_code: 'REFUND_RECONCILIATION_REQUIRED',
      provider_payload: confirmed,
    })
    .eq('id', operation!.id);

  const { error: rentalUpdateError } = await db
    .from('proxnum_rentals')
    .update({
      status: 'RECONCILIATION_REQUIRED',
      last_sync_error: 'REFUND_RECONCILIATION_REQUIRED',
    })
    .eq('id', rental.id);

  if (operationUpdateError || rentalUpdateError) {
    console.error('Failed to persist refund reconciliation state', {
      rentalId: rental.id,
      operationId: operation!.id,
      operationUpdateError,
      rentalUpdateError,
    });
  }

  // L'annulation est confirmée chez Proxnum.
  // Seul le remboursement reste à réconcilier.
  // Ne surtout pas laisser le catch transformer cet état
  // en CANCEL_PENDING.
  return json({
    success: false,
    status: 'RECONCILIATION_REQUIRED',
    reason: 'REFUND_RECONCILIATION_REQUIRED',
  }, 202);
}
          const { error: operationFinalizeError } = await db.from('proxnum_rental_operations').update({
            status: 'SUCCEEDED',
            error_code: null,
            provider_payload: confirmed,
          }).eq('id', operation!.id);
          if (operationFinalizeError) {
            const { error: rentalReconcileError } = await db.from('proxnum_rentals').update({
              status: 'RECONCILIATION_REQUIRED',
              last_sync_error: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND',
            }).eq('id', rental.id);
            console.error('Refund may have succeeded but cancellation operation finalization failed', { rentalId: rental.id, operationId: operation!.id, operationFinalizeError, rentalReconcileError });
            return json({ success: false, status: 'RECONCILIATION_REQUIRED', reason: 'CANCEL_OPERATION_FINALIZATION_FAILED_AFTER_REFUND' }, 202);
          }
        } else {
          finalStatus = confirmed.status === 'active' ? 'ACTIVE' : 'CANCEL_PENDING';
          await db.from('proxnum_rentals').update({
            status: confirmed.status === 'active' ? 'ACTIVE' : 'CANCEL_PENDING',
            cancel_pending: confirmed.status !== 'active',
            can_cancel: confirmed.canCancel,
            last_provider_status: confirmed.status,
            last_provider_payload: confirmed,
          }).eq('id', rental.id);
          await db.from('proxnum_rental_operations').update({
            status: confirmed.status === 'active' ? 'FAILED' : 'PENDING',
            error_code: confirmed.status === 'active' ? 'CANCEL_REJECTED' : null,
            provider_payload: confirmed,
          }).eq('id', operation!.id);
        }
      }
      return json(
        { success: finalStatus === 'CANCELLED', status: finalStatus },
        finalStatus === 'CANCELLED' ? 200 : finalStatus === 'ACTIVE' ? 409 : 202,
      );
        } catch (e) {
      const err = safeError(e);

      // Un remboursement refusé par la base après confirmation fournisseur
      // nécessite un rapprochement. Ne jamais marquer cette opération FAILED.
      if (err.code === 'REFUND_RECONCILIATION_REQUIRED') {
        const { error: operationUpdateError } = await db
          .from('proxnum_rental_operations')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            error_code: 'REFUND_RECONCILIATION_REQUIRED',
          })
          .eq('id', operation!.id);

        const { error: rentalUpdateError } = await db
          .from('proxnum_rentals')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            cancel_pending: false,
            last_sync_error: 'REFUND_RECONCILIATION_REQUIRED',
          })
          .eq('id', rental.id);

        if (operationUpdateError || rentalUpdateError) {
          console.error('Failed to persist refund reconciliation state', {
            rentalId: rental.id,
            operationId: operation!.id,
            operationUpdateError,
            rentalUpdateError,
          });
        }

        return json({
          success: false,
          status: 'RECONCILIATION_REQUIRED',
          reason: 'REFUND_RECONCILIATION_REQUIRED',
        }, 202);
      }

      // Une erreur réseau ou une réponse incertaine ne prouve pas
      // que Proxnum a refusé l'annulation : on conserve les fonds.
      if (
        err.outcomeUncertain ||
        err.httpStatus === undefined ||
        err.httpStatus >= 500
      ) {
        const { error: operationUpdateError } = await db
          .from('proxnum_rental_operations')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            error_code: err.code,
          })
          .eq('id', operation!.id);

        const { error: rentalUpdateError } = await db
          .from('proxnum_rentals')
          .update({
            status: 'RECONCILIATION_REQUIRED',
            cancel_pending: true,
            last_sync_error: err.code,
          })
          .eq('id', rental.id);

        if (operationUpdateError || rentalUpdateError) {
          console.error('Failed to persist cancellation reconciliation state', {
            rentalId: rental.id,
            operationId: operation!.id,
            operationUpdateError,
            rentalUpdateError,
          });
        }

        return json({
          success: false,
          status: 'RECONCILIATION_REQUIRED',
          reconciliationRequired: true,
        }, 202);
      }

      const { error: operationUpdateError } = await db
        .from('proxnum_rental_operations')
        .update({
          status: 'FAILED',
          error_code: err.code,
        })
        .eq('id', operation!.id);

      if (operationUpdateError) {
        console.error('Failed to persist cancellation failure', {
          rentalId: rental.id,
          operationId: operation!.id,
          operationUpdateError,
        });
      }

      throw new ApiError(err.httpStatus ?? 503, err.code);
    }
  }
  throw new ApiError(400, 'UNKNOWN_ACTION');
}));


// const err = safeError(e);