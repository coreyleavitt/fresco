# Compile-time flags applied to every `nim` invocation in this project.
# Runs inside the Docker dev image (see ./dev).

# Vendored chronos fork at lib/chronos (gitignored). Same pattern as
# amoxtli vendoring fresco at lib/fresco — avoids nimble's URL-based
# dep resolution (broken in nimble v0.22.2 vnext SAT solver for URL
# requires). When upstream chronos lands the contextvars primitive,
# this `--path:` drops in favor of a regular `requires "chronos >= …"`
# in fresco.nimble.
--path:"lib/chronos"
