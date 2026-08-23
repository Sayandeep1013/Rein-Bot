// Supabase connection settings.
//
// The publishable key is PUBLIC by design. It identifies the project, it does not
// authorise anything: every table this game touches is behind RLS, the answer-bearing
// tables (question_bank, question_titles) have no client grant at all, and every write
// goes through a SECURITY DEFINER function. Shipping it in browser JavaScript is the
// intended use. The service_role key is a different thing entirely and must never
// appear in this file -- it lives only in GitHub Actions secrets.
window.REIN_CONFIG = {
  SUPABASE_URL: "https://mxkqivivqultfuattuin.supabase.co",

  // Supabase dashboard -> Settings -> API Keys -> the `anon` / `publishable` key.
  SUPABASE_ANON_KEY: "PASTE_PUBLISHABLE_KEY_HERE",
};
