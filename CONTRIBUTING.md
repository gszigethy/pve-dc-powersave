# Contributing

Contributions are welcome. Please open an issue before substantial changes so
the design and Proxmox compatibility impact can be discussed.

## Development

Run the test suite from the repository root on a system with Perl and the
standard Perl testing modules:

```sh
prove -Ilib t
```

Keep changes focused, preserve the safety-first behavior described in
`docs/DESIGN.md`, and update `README.md` or `CHANGELOG.md` when user-visible
behavior changes.

Pull requests should explain the Proxmox VE versions tested and include the
relevant test output.

