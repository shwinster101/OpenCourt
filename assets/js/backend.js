/* ============================================================
   OPENCOURT — backend client (Supabase via supabase-js UMD)
   ============================================================
   Thin wrapper over the tables, views and RPC functions defined in
   supabase/migrations/. Every write is an RPC whose rules live in SQL
   under auth.uid(); this file never decides who the caller is.

   Backend.enabled is false when config.js has no URL/key or the
   supabase-js script did not load; app.js then runs in offline mode.
   ============================================================ */
(function () {
  const cfg = window.OPENCOURT_CONFIG || {};
  const enabled = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY && window.supabase && window.supabase.createClient);

  let client = null;
  let session = null;
  let profile = null;

  // Human wording for the error names the SQL functions raise.
  const MESSAGES = {
    auth_required: 'Sign-in failed. Try again.',
    profile_required: 'Pick a name first.',
    rate_limited: 'You already reported this court in the last 15 minutes.',
    private_court: 'Private courts take no reports.',
    unknown_court: 'This court is not in the catalogue.',
    invalid_username: 'Usernames are 3–20 characters: a–z, 0–9, underscore.',
    username_taken: 'That username is taken.',
    invalid_skill: 'Skill is 1 to 5.',
    sport_not_at_court: 'That sport is not played at this court.',
    starts_in_past: 'The start time has passed.',
    too_far_ahead: 'Pickups can be set up to 30 days ahead.',
    pickup_full: 'This pickup is full.',
    pickup_not_open: 'This pickup is no longer open.',
    already_joined: 'You are already in.',
    not_joined: 'You are not in this pickup.',
    organiser_cannot_leave: 'Organisers cancel instead of leaving.',
    not_organiser: 'Only the organiser can do that.',
    no_invitation: 'There is no invitation to answer.',
    already_attendee: 'Already on the roster.',
    unknown_player: 'No such player.',
    cannot_invite_self: 'You are already in your own pickup.',
    unknown_pickup: 'This pickup no longer exists.'
  };

  function wrap(e) {
    const raw = (e && (e.message || e.error_description || e.msg)) || String(e || 'error');
    const name = /^[a-z_]+$/.test(raw) ? raw : null;
    const out = new Error(name && MESSAGES[name] ? MESSAGES[name] : raw);
    out.code = name || (e && e.code) || 'error';
    out.hint = e && e.hint;
    return out;
  }

  function sb() {
    if (!client) {
      client = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
      });
    }
    return client;
  }

  async function rpc(name, args) {
    const { data, error } = await sb().rpc(name, args || {});
    if (error) throw wrap(error);
    return data;
  }
  const one = (d) => (Array.isArray(d) ? d[0] || null : d);

  async function getSession() {
    const { data } = await sb().auth.getSession();
    session = data && data.session;
    return session;
  }

  // Anonymous identity on first write (FOUNDATION FR-60); upgradeable to an account later (FR-61).
  async function ensureSession() {
    const s = await getSession();
    if (s) return s;
    const { data, error } = await sb().auth.signInAnonymously();
    if (error) throw wrap(error);
    session = data.session;
    return session;
  }

  async function signInWithEmail(email) {
    const { error } = await sb().auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname } });
    if (error) throw wrap(error);
    return true;
  }

  // Link an email to the current (anonymous) user: same uid, history kept (FR-61).
  async function linkEmail(email) {
    await ensureSession();
    const { error } = await sb().auth.updateUser({ email });
    if (error) throw wrap(error);
    return true;
  }

  async function signOut() {
    await sb().auth.signOut();
    session = null; profile = null;
  }

  // ---- courts and reports (M1) ---------------------------------------------------------------
  async function fetchCourts() {
    const { data, error } = await sb().from('courts_live').select('*').order('name');
    if (error) throw wrap(error);
    return data;
  }

  async function submitReport(courtId, status) {
    await ensureSession();
    return rpc('submit_report', { p_court_id: courtId, p_status: status });
  }

  // ---- identity (M2) ------------------------------------------------------------------------
  async function myProfile(force) {
    if (profile && !force) return profile;
    const s = await getSession();
    if (!s) return null;
    const { data, error } = await sb().from('profiles').select('*').eq('id', s.user.id).maybeSingle();
    if (error) throw wrap(error);
    profile = data;
    return profile;
  }

  async function upsertProfile(username, displayName, skill) {
    await ensureSession();
    profile = one(await rpc('upsert_profile', {
      p_username: username, p_display_name: displayName, p_skill: skill ? Number(skill) : null, p_metro: cfg.METRO || 'LA'
    }));
    return profile;
  }

  // ---- pickups (M2) -------------------------------------------------------------------------
  async function listPickups(courtId) {
    let q = sb().from('open_pickups').select('*').order('starts_at');
    if (courtId) q = q.eq('court_id', courtId);
    const { data, error } = await q;
    if (error) throw wrap(error);
    return data;
  }

  async function myPickups() {
    if (!(await getSession())) return [];
    const { data, error } = await sb().from('my_pickups').select('*').order('starts_at');
    if (error) throw wrap(error);
    return data;
  }

  const createPickup = ({ courtId, sport, startsAt, capacity, note }) =>
    rpc('create_pickup', { p_court_id: courtId, p_sport: sport, p_starts_at: startsAt, p_capacity: capacity, p_note: note || null }).then(one);
  const joinPickup = (id) => rpc('join_pickup', { p_pickup_id: id }).then(one);
  const leavePickup = (id) => rpc('leave_pickup', { p_pickup_id: id });
  const cancelPickup = (id) => rpc('cancel_pickup', { p_pickup_id: id }).then(one);
  const respondToInvitation = (id, accept) => rpc('respond_to_invitation', { p_pickup_id: id, p_accept: !!accept });
  const pickupByToken = (token) => rpc('pickup_by_token', { p_token: token }).then(one);
  const roster = (id) => rpc('pickup_roster', { p_pickup_id: id });

  // ---- inbox (M2) ---------------------------------------------------------------------------
  async function notifications(limit) {
    if (!(await getSession())) return [];
    const { data, error } = await sb().from('my_notifications').select('*').is('read_at', null)
      .order('created_at', { ascending: false }).limit(limit || 20);
    if (error) throw wrap(error);
    return data;
  }
  const markRead = (ids) => rpc('mark_notifications_read', { p_ids: ids });

  window.Backend = {
    enabled,
    getSession, ensureSession, signInWithEmail, linkEmail, signOut,
    userId: () => (session && session.user && session.user.id) || null,
    fetchCourts, submitReport,
    myProfile, upsertProfile,
    listPickups, myPickups, createPickup, joinPickup, leavePickup, cancelPickup, respondToInvitation, pickupByToken, roster,
    notifications, markRead
  };
})();
