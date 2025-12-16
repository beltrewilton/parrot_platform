[
  # Ignore Membrane Framework callback spec mismatches
  # Membrane uses dynamic specs that Dialyzer can't always verify
  {"apps/parrot_media/lib/parrot_media/*_pipeline.ex", :callback_spec_type_mismatch},

  # Ignore test files with intentional spec violations for testing
  {"apps/*/test/**/*.exs", :no_return},

  # Known false positives in gen_statem callbacks
  # gen_statem allows flexible return types that Dialyzer flags
  {"apps/parrot_sip/lib/parrot_sip/transaction_statem.ex", :callback_type_mismatch},
  {"apps/parrot_sip/lib/parrot_sip/dialog_statem.ex", :callback_type_mismatch},
  {"apps/parrot_transport/lib/parrot_transport/connection.ex", :callback_type_mismatch}
]
