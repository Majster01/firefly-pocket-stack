# Security

firefly-pocket-stack runs a personal-finance server with real bank data, so a vulnerability here can expose someone's finances. Please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the repository's **Security** tab → **Report a vulnerability**. Do not open a public issue or pull request for it.

Say what is affected (a service, a script, the Caddyfile), how to reproduce it, and what an attacker gains. You will get an answer within a week.

## In scope

- This repository: the compose file, the Caddyfile, the scripts, the crontab, the category suggester and the Terraform files.
- The way this stack deploys and configures the apps it runs, for example a route that exposes an internal API or a secret that reaches a log.

Bugs in the apps themselves belong to their own projects: [Firefly III](https://github.com/firefly-iii/firefly-iii/security), the [Data Importer](https://github.com/firefly-iii/data-importer/security) (or [our fork](https://github.com/Majster01/data-importer) for its `app/FireflyX` code), and [Firefly Pocket](https://github.com/Majster01/firefly-pocket).

## Never send

Real bank data, tokens, keys or `.env` files, yours or anyone else's, in a report or anywhere in this repository. Use invented values in examples and tests.
