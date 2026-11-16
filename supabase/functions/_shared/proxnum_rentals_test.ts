import { buyRental, cancelRental, getRentalCatalog, getRentalStatus, ProxnumRentalError } from './proxnum_rentals.ts';

function assertEquals(actual: unknown, expected: unknown) { if (actual!==expected) throw new Error(`Expected ${String(expected)}, got ${String(actual)}`); }

const provider={slug:'proxnum',endpoint:'https://proxnum.com'};
function mockFetch(fn:(url:string,init:RequestInit)=>Response|Promise<Response>) {
  const original=globalThis.fetch;
  globalThis.fetch=((input:RequestInfo|URL,init?:RequestInit)=>fn(String(input),init??{})) as typeof fetch;
  return ()=>{globalThis.fetch=original;};
}

Deno.test('rental catalog uses live duration, country, service and price data',async()=>{
  Deno.env.set('PROVIDER_SECRETS',JSON.stringify({proxnum:{apiToken:'test-token'}}));
  const restore=mockFetch((url)=>{assertEquals(url,'https://proxnum.com/api/v1/resell/rental/catalog?country=187&hours=168');return new Response(JSON.stringify({ok:true,country:'187',hours:168,durations:[{hours:168,label:'1 week'}],countries:[{id:'187',name:'USA'}],services:[{code:'wa',name:'WhatsApp',price:4.2,stock:35}]}));});
  try {const c=await getRentalCatalog(provider,'187',168);assertEquals(c.durations[0].hours,168);assertEquals(c.services[0].stock,35);assertEquals(c.services[0].price,4.2);} finally {restore();}
});

Deno.test('buy sends the fresh provider price ceiling and parses confirmed data',async()=>{
  Deno.env.set('PROVIDER_SECRETS',JSON.stringify({proxnum:{apiToken:'test-token'}}));
  const restore=mockFetch((url,init)=>{assertEquals(url,'https://proxnum.com/api/v1/resell/rental/buy');assertEquals(JSON.parse(String(init.body)).max_price,4.2);return new Response(JSON.stringify({ok:true,rental:{id:512,phone:'14155550123',status:'active',hours:168,amount_paid:4.2,expires_at:'2026-10-23T00:00:00Z'}}));});
  try {const r=await buyRental(provider,'wa','187',168,4.2);assertEquals(r.rentalId,'512');assertEquals(r.providerPrice,4.2);} finally {restore();}
});

Deno.test('ambiguous buy timeout is marked uncertain and is not represented as a refusal',async()=>{
  Deno.env.set('PROVIDER_SECRETS',JSON.stringify({proxnum:{apiToken:'test-token'}}));
  const restore=mockFetch(()=>{throw new Error('network timeout');});
  try {let caught:unknown; try {await buyRental(provider,'wa','187',168,4.2);} catch(e) {caught=e;} if(!(caught instanceof ProxnumRentalError)) throw new Error('Expected ProxnumRentalError'); assertEquals(caught.message,'Proxnum network request failed'); assertEquals(caught.outcomeUncertain,true);} finally {restore();}
});

Deno.test('cancel preserves the provider pending state for later reconciliation',async()=>{
  Deno.env.set('PROVIDER_SECRETS',JSON.stringify({proxnum:{apiToken:'test-token'}}));
  const restore=mockFetch((url,init)=>{assertEquals(url,'https://proxnum.com/api/v1/resell/rental/cancel');assertEquals(JSON.parse(String(init.body)).id,512);return new Response(JSON.stringify({ok:true,pending:true,rental:{id:512,status:'cancelling',cancel_pending:true}}),{status:202});});
  try {const result=await cancelRental(provider,'512');assertEquals(result.pending,true);assertEquals(result.status,'cancelling');} finally {restore();}
});

Deno.test('rental status keeps provider message identifiers for de-duplication',async()=>{
  Deno.env.set('PROVIDER_SECRETS',JSON.stringify({proxnum:{apiToken:'test-token'}}));
  const restore=mockFetch(()=>new Response(JSON.stringify({ok:true,rental:{id:512,phone:'14155550123',status:'active',messages:[{id:9001,sender:'WhatsApp',text:'Code 123456',code:'123456',date:'2026-10-16T00:00:00Z'},{sender:'WhatsApp',text:'Code 123456',date:'2026-10-16T00:01:00Z'}]}})));
  try {const s=await getRentalStatus(provider,'512');assertEquals(s.messages[0].id,9001);assertEquals(s.messages[0].code,'123456');if(!String(s.messages[1].id).includes('2026-10-16T00:01:00Z')) throw new Error('Fallback message ID must include provider timestamp for stable deduplication');} finally {restore();}
});
