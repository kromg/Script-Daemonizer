#!perl -T

use Test::More tests => 1;
use Script::Daemonizer;

# daemonize() croaks if odd number of elemets was passed
eval q(
    Script::Daemonizer::daemonize(
        name => 'Test',
        keep =>
    );
);

like($@, qr/Odd number/, 'daemonize() must croak() if odd number of elements in config');

