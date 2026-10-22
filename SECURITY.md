# Security Policy

Quietype processes everything you say on your own Mac. It has Microphone, Accessibility and (for meeting notes) Screen & System Audio Recording permissions, so security issues are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through [GitHub's private vulnerability reporting](https://github.com/noahweiss3/quietype/security/advisories/new) for this repository.

Include what you found, how to reproduce it, and the macOS version and Quietype commit you tested. You'll get an acknowledgement within a few days, and a fix or mitigation plan once the report is confirmed. Credit is given in the release notes unless you'd rather stay anonymous.

## Scope

In scope:

- Anything that sends audio, transcripts, notes or history off the machine
- Model downloads that could be tampered with or replaced
- Ways for dictated or meeting content to trigger unintended actions, for example through the paste mechanism or prompt injection that escapes the output guard
- Local data stored with weaker protection than documented (the README's [Privacy](README.md#privacy) section lists everything Quietype stores)

Bugs in third-party projects (llama.cpp, FluidAudio, the models themselves) should be reported upstream, but a heads-up here is welcome if they affect Quietype.

## Supported versions

There is no tagged release yet, so only `main` is supported. Fixes land there and will be in the first release.
