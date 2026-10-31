# Security Policy

## Scope

This is a DevOps portfolio project: a local Vagrant lab for learning.
It runs only on a private lab network and is not meant for production
or the public internet. The scripts contain `CHANGE_ME` placeholders
instead of real passwords.

The security decisions and known limitations of the lab are described
in the [README](README.md#security-decisions).

## Supported versions

There are no releases. Only the latest version on the `main` branch is
maintained.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately on GitHub: go to the **Security** tab of this
repository and click **Report a vulnerability**. Please describe:

- the affected file (for example `VagrantFile/app.sh` or `app/app.py`),
- what the problem is and how to reproduce it,
- what could happen if someone used it.

This is a personal learning project, so there is no guaranteed response
time, but I will read every report and fix confirmed problems on `main`.
