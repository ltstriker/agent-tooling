# Contributing

## Commit and PR messages

Use Conventional-Commit subjects no longer than 72 characters. Every pull
request description includes the changed end-to-end call graph before and
after. Bug fixes mark the faulty Before hop and link the issue.

```text
Before
  exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
    └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  ← BUG: returns before the socket binds
         └─ attach_stdio (Guest · src/guest/src/io.rs:12)              — never reached

After
  exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
    └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  — awaits the bind future
         └─ attach_stdio (Guest · src/guest/src/io.rs:12)

Fixes #1042
```
