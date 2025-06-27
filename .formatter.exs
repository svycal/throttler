[
  import_deps: [:ecto, :ecto_sql],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: [
    # Throttler DSL
    throttle: 3,
    throttle: 4
  ],
  export: [
    locals_without_parens: [
      throttle: 3,
      throttle: 4
    ]
  ]
]
