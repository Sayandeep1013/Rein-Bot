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
  // This is the newer `sb_publishable_` format. The legacy `anon` JWT for this project
  // also works; the publishable key is used because it is the format Supabase is
  // moving to and it is not a JWT, so it cannot be mistaken for a session token.
  SUPABASE_ANON_KEY: "sb_publishable_Y1pzH2bR7iLP5pwGH36BYQ_7OABNQy8",
};
