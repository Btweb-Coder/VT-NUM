import { admin, authenticatedUser, handle, json } from '../_shared/core.ts';
Deno.serve(handle(async request => { const user=await authenticatedUser(request); const {error}=await admin().from('wallets').upsert({user_id:user.id},{onConflict:'user_id',ignoreDuplicates:true}); if(error) throw error; return json({success:true}); }));
