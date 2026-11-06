<?php
/*
 * Firefly III's part of setup, without its web UI (Setup UI step 2; the spike in
 * spikes/firefly-bootstrap found the way). scripts/setup.sh runs it inside the
 * app container, as `php -r` with this file's code, and sends its input as one
 * JSON object on stdin, so the password is in no command line:
 *
 *   {"email": "...", "password": "...", "tokens": ["Firefly Pocket importer", ...],
 *    "client": {"name": "Firefly Pocket Console", "redirect": "https://admin.<domain>/oauth/callback"}}
 *
 *   email, password   create the owner account, the way /register does, only while
 *                     there is no account at all. Without them nothing is created
 *   tokens            mint one Personal Access Token per name, for the account with
 *                     that email (or the only account). Minting a name again revokes
 *                     the older tokens of that name, so it doubles as rotation
 *   client            the console's "Sign in with Firefly III": an authorization-code
 *                     client with PKCE and no secret (public), registered once by its
 *                     name; run again, it keeps the client and moves it to the
 *                     redirect URL given, as after a change of domain
 *
 * Every step can run again. The answer is one line on stdout, after the marker
 * below, so that log lines Firefly III prints on the way cannot be mistaken for it:
 *
 *   FIREFLY_POCKET_BOOTSTRAP {"users": 0, "user": "created", "email": "...",
 *                             "tokens": {"<name>": {"token": "...", "expires_at": "..."}},
 *                             "client": {"id": "...", "client": "created" or "kept"}}
 *
 * users is how many accounts there were before. It uses Firefly III's internal
 * classes, which a release can change: the boot test runs it on every new
 * Firefly III image before the bump merges (scripts/boot-test.sh).
 */
chdir('/var/www/html');
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use FireflyIII\Events\Security\System\NewUserRegistered;
use FireflyIII\Notifications\Notifiables\OwnerNotifiable;
use FireflyIII\Repositories\User\UserRepositoryInterface;
use FireflyIII\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Schema;
use Laravel\Passport\ClientRepository;

function answer(array $out, int $status = 0): never
{
    echo "\nFIREFLY_POCKET_BOOTSTRAP ", json_encode($out), "\n";
    exit($status);
}

try {
    $in = json_decode((string) stream_get_contents(STDIN), true, 8, JSON_THROW_ON_ERROR);
    if (!is_array($in)) {
        answer(['error' => 'the input is not a JSON object'], 2);
    }
    $email    = is_string($in['email'] ?? null) ? $in['email'] : '';
    $password = is_string($in['password'] ?? null) ? $in['password'] : '';
    $names    = array_values(array_filter((array) ($in['tokens'] ?? []), 'is_string'));

    $users = app(UserRepositoryInterface::class);
    $out   = ['users' => $users->count(), 'user' => 'kept'];

    // 1. The owner account, as /register creates it: the registration event
    //    gives it the owner role and its user group.
    if ('' !== $email && '' !== $password && 0 === $out['users']) {
        $user           = $users->store(['blocked' => false, 'blocked_code' => null, 'email' => $email]);
        $user->password = Hash::make($password);
        $user->save();
        event(new NewUserRegistered(new OwnerNotifiable(), $user));
        $out['user'] = 'created';
    }

    if ([] !== $names) {
        // 2. The personal access client, created the way Firefly III's OAuth page
        //    does when it is missing.
        if (0 === DB::table('oauth_clients')->where('grant_types', '["personal_access"]')->whereNull('owner_id')->count()) {
            app(ClientRepository::class)->createPersonalAccessGrantClient('Firefly III Personal Access Grant Client', null);
        }

        // 3. One token per app, so each can be revoked alone.
        $user = '' !== $email ? User::where('email', $email)->first() : null;
        if (null === $user && 1 === User::count()) {
            $user = User::first();
        }
        if (null === $user) {
            answer(['error' => sprintf('Firefly III has %d accounts and none is %s', User::count(), $email ?: 'given')] + $out, 3);
        }
        $out['email'] = $user->email;
        foreach ($names as $name) {
            $user->tokens()->where('name', $name)->where('revoked', false)->update(['revoked' => true]);
            $result               = $user->createToken($name);
            $out['tokens'][$name] = ['token' => $result->accessToken, 'expires_at' => (string) $result->token->expires_at];
        }
    }

    // 4. The console's client. Public: the console holds no secret, and PKCE
    //    stands in for one. Passport keeps the redirect URLs in redirect_uris
    //    (JSON) since version 13, in redirect before.
    $client = is_array($in['client'] ?? null) ? $in['client'] : [];
    $cname  = is_string($client['name'] ?? null) ? $client['name'] : '';
    $target = is_string($client['redirect'] ?? null) ? $client['redirect'] : '';
    if ('' !== $cname && '' !== $target) {
        if (!str_starts_with($target, 'https://')) {
            answer(['error' => 'the client\'s redirect URL must be https://'] + $out, 2);
        }
        $existing = DB::table('oauth_clients')->where('name', $cname)->where('revoked', false)->first();
        if (null === $existing) {
            $made          = app(ClientRepository::class)->createAuthorizationCodeGrantClient($cname, [$target], false);
            $out['client'] = ['id' => (string) $made->getKey(), 'client' => 'created'];
        } else {
            $column = Schema::hasColumn('oauth_clients', 'redirect_uris') ? 'redirect_uris' : 'redirect';
            $value  = 'redirect_uris' === $column ? json_encode([$target]) : $target;
            DB::table('oauth_clients')->where('id', $existing->id)->update([$column => $value]);
            $out['client'] = ['id' => (string) $existing->id, 'client' => 'kept'];
        }
    }
    answer($out);
} catch (Throwable $e) {
    answer(['error' => get_class($e) . ': ' . $e->getMessage()], 1);
}
