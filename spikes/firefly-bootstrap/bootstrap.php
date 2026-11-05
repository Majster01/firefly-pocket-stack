<?php
/*
 * firefly-pocket-stack spike: set up Firefly III for the other apps without its web UI.
 * Runs inside the Firefly III container:  php < bootstrap.php
 * Every step is idempotent, and its result is one JSON line on stdout.
 *
 *   FX_EMAIL, FX_PASSWORD     create the owner account, only while there is no user
 *   FX_TOKENS                 comma-separated names; mints one personal access token each,
 *                             revoking older tokens of the same name
 *   FX_CLIENT_NAME, FX_REDIRECT  registers a confidential authorization-code client once
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
use Laravel\Passport\ClientRepository;

$out = [];
$users = app(UserRepositoryInterface::class);
$email = getenv('FX_EMAIL') ?: null;

// 1. The owner account, as /register would create it (role and user group come from the event).
if ($email && getenv('FX_PASSWORD') && 0 === $users->count()) {
    $user = $users->store(['blocked' => false, 'blocked_code' => null, 'email' => $email]);
    $user->password = Hash::make(getenv('FX_PASSWORD'));
    $user->save();
    event(new NewUserRegistered(new OwnerNotifiable(), $user));
    $out['user'] = 'created';
} else {
    $out['user'] = 'kept';
}

// 2. The personal access client, created the way Firefly III's OAuth page does when it is missing.
$clients = app(ClientRepository::class);
if (0 === DB::table('oauth_clients')->where('grant_types', '["personal_access"]')->whereNull('owner_id')->count()) {
    $clients->createPersonalAccessGrantClient('Firefly III Personal Access Grant Client', null);
}

// 3. Tokens, one per app, so each can be revoked alone. Minting a name again rotates it:
//    the older tokens of that name are revoked.
if ($email && getenv('FX_TOKENS')) {
    $user = User::where('email', $email)->firstOrFail();
    foreach (array_filter(array_map('trim', explode(',', getenv('FX_TOKENS')))) as $name) {
        $user->tokens()->where('name', $name)->where('revoked', false)->update(['revoked' => true]);
        $result = $user->createToken($name);
        $out['tokens'][$name] = ['token' => $result->accessToken, 'expires_at' => (string) $result->token->expires_at];
    }
}

// 4. An OAuth client for "Sign in with Firefly III", registered once.
if (getenv('FX_CLIENT_NAME') && getenv('FX_REDIRECT')) {
    $existing = DB::table('oauth_clients')->where('name', getenv('FX_CLIENT_NAME'))->where('revoked', false)->first();
    if ($existing) {
        $out['client'] = ['id' => $existing->id, 'secret' => null];
    } else {
        $client = $clients->createAuthorizationCodeGrantClient(getenv('FX_CLIENT_NAME'), [getenv('FX_REDIRECT')], true);
        $out['client'] = ['id' => $client->getKey(), 'secret' => $client->plainSecret];
    }
}

echo json_encode($out), "\n";
