## GPU dashboard (server-push WebSocket) — thin entrypoint.
##
## All sources live in ./gpu_dashboard/ (main.nim + collectors.nim +
## dashboard.html). See ./gpu_dashboard/README.md for usage.

import ./gpu_dashboard/main

when isMainModule:
  main()
