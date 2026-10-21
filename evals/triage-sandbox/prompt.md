---
max_turns: 6
allowed_tools: [Skill, Read]
runs: 2
---

I'm working on a web app. `src/server.ts` starts the dev server on 127.0.0.1:8917, and the Playwright config's webServer uses it. I just ran `npx playwright test` and got:

```
Error: listen EPERM: operation not permitted 127.0.0.1:8917
    at Server.setupListenHandle [as _listen2] (node:net:1872:21)
[WebServer] process exited with code 1
Error: Process from config.webServer was not able to start. Exit code: 1
```

What's the cause, and what exactly should happen next? Don't touch any files, just tell me the plan.
