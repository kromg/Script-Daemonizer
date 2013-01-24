#!perl -T

use Test::More tests => 2;
use Script::Daemonizer;

my $gid = (split " ", $( )[0];

eval qq(
    my \$daemon = new Script::Daemonizer();
    \$daemon->drop_privileges(
        euid => $>,
        egid => $gid,
        uid  => $<,
        gid  => $gid,
    );
);

ok (! $@, "call to drop_privileges() with explicit parameters failed: $@");


eval qq(
    my \$daemon = new Script::Daemonizer(
        drop_privileges => {
            euid => $>,
            egid => $gid,
            uid  => $<,
            gid  => $gid,
        },
    );
    \$daemon->drop_privileges();
);

ok (! $@, "call to drop_privileges() with implicit parameters failed: $@");
