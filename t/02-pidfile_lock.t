#!perl -T

use Test::More tests => 1;
use Config;
use Cwd;

my $thisperl = $Config{perlpath};
if ($^O ne 'VMS') {
    $thisperl .= $Config{_exe} unless $thisperl =~ m/$Config{_exe}$/i;
}
my $testdir = getcwd;

SKIP: {
    eval q{ use File::Temp qw/tempfile/; };
    skip q(File::Temp required), 1 
        if $@;

    my ($tfh, $tfname) = tempfile( "testdaemon_XXXXXX", UNLINK => 1 );
    unlink $tfname;

    {
        my $prev = select $tfh;
        ++$|;
        select $prev;
    }
    print $tfh <<"SCRIPT1";
#!$thisperl
#line 2 $tfname
use strict;
use warnings;

BEGIN {
    our \@INC = (
SCRIPT1

    for (@INC) {
        print $tfh qq(        "$_",\n);
    }

    print $tfh <<'SCRIPT2';
    );
};

use Script::Daemonizer qw/ daemonize /;

# $Script::Daemonizer::DEBUG = 'testdaemon_dbg_'.int(rand(1000));

delete @ENV{qw(PATH IFS CDPATH ENV BASH_ENV)};   # Make %ENV safer

SCRIPT2

print $tfh <<"SCRIPT3";

chdir("$testdir") 
    or die "Unable to chdir to $testdir";

my \$pidfile = "$testdir/testdaemon.pid";

daemonize (
    pidfile         => \$pidfile,
    working_dir     => "$testdir",
);

print "Everything went good.\n";

sleep 4;

print "Test daemon complete.\n";

# unlink \$pidfile;

SCRIPT3

    delete @ENV{qw(PATH IFS CDPATH ENV BASH_ENV)};

    my $fileno = fileno($tfh);
    defined $fileno or fail("Unable to get fd of generated script");


    my @output;
    my $cmd = "$thisperl -T /proc/$$/fd/$fileno";
    open(DAEMON, "$cmd 2>&1 |")
        or fail("launch daemon', reason: '$!");
    @output = <DAEMON>;
    close DAEMON;

    open (NEWDAEMON, "$cmd 2>&1 |")
        or fail("launch second daemon', reason: '$!");
    @output = <NEWDAEMON>;
    close NEWDAEMON;

    PIDLOCK: {
        for (@output) {
            pass("launch daemon and lock pidfile"), last PIDLOCK
                if /another instance running/;
        }
        fail("launch daemon and lock pidfile");
    }
}




