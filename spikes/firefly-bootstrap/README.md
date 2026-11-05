# Spike: set up Firefly III without its web UI

Answers the two open questions of the Setup UI design: can the stack create the Firefly III tokens for the other apps, and can it register an OAuth client for "Sign in with Firefly III", with nobody clicking through Firefly III? Both answers are yes, on `fireflyiii/core:version-6.7.9` (Passport 13.9.0), run on 2026-11-03.

## Results

- **No built-in command fits.** `tinker` is not installed in the image. `system:create-first-user` (formerly `firefly-iii:create-first-user`) refuses unless `app.env` is `testing`, and the image caches its config, so setting `APP_ENV` for one command does not change that.
- **A script piped into `php` does all of it.** [`bootstrap.php`](bootstrap.php) boots Firefly III's own Laravel app inside the `app` container and uses only Firefly III's and Passport's classes:
  - creates the owner account the way `/register` does (the registration event gives it the owner role); `/register` reports registration closed afterwards;
  - creates the personal access client the way Firefly III's OAuth page does when it is missing;
  - mints one personal access token per app. Minting a name again revokes the older tokens of that name, so it doubles as rotation: the old token answers 401 and the new one 200;
  - registers a confidential authorization-code client and returns its secret once, as JSON. `php artisan passport:client --no-interaction` also works, but prints the secret in a table.
- **Tokens expire after one year**, including the ones made by hand in the web UI: Passport's default, not changed by Firefly III. Something must re-mint them before then.
- **Sign-in works end to end** ([`oauth_flow.py`](oauth_flow.py)): authorization code with PKCE, token exchange, `GET /api/v1/about/user` with the result, refresh. Firefly III asks for approval once; later sign-ins come straight back.
- **2FA applies.** With 2FA on and only the password given, `/oauth/authorize` shows the one-time password form, not the approval form. After the code, it issues the authorization code.
- **Risk:** the script calls Firefly III's internal classes (`UserRepositoryInterface`, `NewUserRegistered`, `ClientRepository`), which can change in any Firefly III release. Run it against every new Firefly III image in CI before the bump is merged.

## Run it

```sh
docker compose up -d        # Firefly III on http://127.0.0.1:8080, empty database
docker compose exec -T \
  -e FX_EMAIL=owner@example.com -e 'FX_PASSWORD=Spike-Passw0rd-2026!' \
  -e 'FX_TOKENS=Firefly Pocket importer,Firefly Pocket suggester' \
  -e 'FX_CLIENT_NAME=Firefly Pocket Console' -e FX_REDIRECT=http://127.0.0.1:9999/callback \
  app php < bootstrap.php | grep '^{' > out.json
python3 -c "import json; c=json.load(open('out.json'))['client']; json.dump(c, open('client.json','w'))"
python3 oauth_flow.py
docker compose down -v
```

Every value here is invented. Never point this at a real server: it mints tokens and revokes older ones of the same name.
