#!perl -T

use Test::More tests => 2;
use Script::Daemonizer;

# drop_privileges() croaks if odd number of elemets was passed
eval q(
    Script::Daemonizer::drop_privileges(
        euid => 0,
        egid =>
    );
);

like($@, qr/Odd number/, 'drop_privileges() must croak() if odd number of elements in config');

my $gid = (split " ", $( )[0];
eval qq(
    Script::Daemonizer::drop_privileges(
        euid => $>,
        egid => $gid,
        uid  => $<,
        gid  => $gid,
    );
);

ok (! $@, "drop_privileges() failed: $@");

