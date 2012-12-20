package Script::Daemonizer;

use 5.006;
use strict;
use warnings;
use Carp qw/croak/;

@Script::Daemonizer::ISA = qw(Exporter);
@Script::Daemonizer::EXPORT = ();
@Script::Daemonizer::EXPORT_OK = qw(daemonize drop_privileges_to);

$Script::Daemonizer::VERSION = '0.00.01_01';

# ------------------------------------------------------------------------------
# 'Private' functions
# ------------------------------------------------------------------------------

# fork() a child 
sub _fork() {
    defined(my $pid = fork()) or croak "Cannot fork: $!";
    exit 0 if $pid;     # parent exits here
}

# ------------------------------------------------------------------------------
# 'Public' functions
# ------------------------------------------------------------------------------

sub daemonize {
    croak "Odd number of arguments in configuration!"
        if @_ %2;
}


1; # End of Script::Daemonizer

__END__

# ------------------------------------------------------------------------------
# POD
# ------------------------------------------------------------------------------

=head1 NAME

Script::Daemonizer - Turns your script into a UNIX daemon process (the easy way).

=head1 VERSION

Version 0.00.01_01

=head1 SYNOPSIS

    use Script::Daemonizer;
    ...
    Script::Daemonizer::daemonize();
    Script::Daemonizer::drop_privileges($to_uid, $to_gid);
    ...

=head1 DESCRIPTION

This module turns your script into a UNIX daemon by requiring no modifications 
other than the two lines shown above, thus letting you concentrate on solving 
your problem, rather than on writing a daemon. Just get your job done, then 
turn your script into a daemon by calling daemonize(). 

It redirects all messages to syslog by default. 

What C<daemonize()> does is: 

=over 4

=item 1.* it sets C<umask()> to 0. You must then set explicitly file and 
directory permissions upon creating them, or restore C<umask()> after 
initialization;

=item 2.  it calls C<fork()>, then the parent exits;

=item 3.  it calls L<POSIX::setsid()>, so the process becomes session leader;

=item 4.  it calls C<fork()> again, then the parent exits; 

=item 5.* it changes its working directory to "/";

=item 6.* it closes all open file descriptors;

=item 7.* it ties STDOUT and STDERR to Syslog using  L<Script::Daemon::Syslog> 
so that all output is logged to syslog;

=item 8.* it tries to open STDIN from /dev/null;

=back

Steps marked by * are configurable; some additional steps are also available if
explicitly requested; see L<ADVANCED USAGE> for detsils.

=head1 EXPORT

Nothing is exported by default, and nothing needs to be imported. You can 

    use Script::Daemonize qw(daemonize);
    ...
    daemonize();

or simply call the C<daemonize()> functions with its full name: 

    use Script::Daemonize;
    ...
    Script::Daemonizer::daemonize();


=head1 SUBROUTINES/METHODS

=head2 C<daemonize()>

It runs through all the steps required to send your program to background as a
daemon. Its behaviour can be customized a little, see L<ADVANCED USAGE> for
details.

=head2 C<drop_privileges()>

    drop_privileges($to_euid, $to_egid, $drop_uid_gid_also);

Tries to drop priviles to given EUID/EGID. The third parameter is a boolean; if
true, then real UID/GID will be set to $to_euid, $to_egid. 

Privileges dropping can be configured directly when C<daemonize()>-ing, but it
happens before trying to open pidfile (if any, see L<ADVANCED OPTIONS> for
details). So you may want to drop privileges explicitly I<after> the call to
C<daemonize()> and, optionally, after you opened some other files with high
privilegs (although this is discourages unless striclty necessary). 


=head1 ADVANCED USAGE

I strive to make this module to support "standard" daemon features
out-of-the-box (for some definition of "standard"). Some of these features can
be configured, and some other are enabled only if configured. 

=head2 SYNOPSYS

Advanced configuration syntax is the following: 

    use Script::Daemonizer;
    Script::Daemonizer::daemonize(
        name            => "My wonderful new daemon",      # tag for logging
        do_not_close_fh => 1,                              # don't touch my filehandles!
        umask           => $my_umask,                      # set umask to $my_umask
        working_dir     => "/var/ftp",                     # try to chdir here
    );

    # or

    Script::Daemonizer::daemonize(
        name => "My wonderful new daemon",                 # tag for logging
        keep => [ 0, 1, 2, $myfh, $anotherfh, 42 ],        # don't close these FD/FH
    );

    # or

    Script::Daemonizer::daemonize(
        name                  => "ddddddaeeemonnn",        # tag for logging
        do_not_tie_stdhandles => 1,                        # skip tie-to-syslog
    );
    
    

=head2 OPTIONAL ACTIONS

Some options have no default and thus corresponding actions are skipped if not
configured. These are: 

=over 4

=item * Creation of pid_file and locking -- it implicitly provides a method to
ensure that only one copy of your daemon is running at once.

=item * Privileges drop

=back

=head2 ADVANCED OPTIONS

Advanced options are the following: 

=head3 B<name>

Sets the name of the daemon. This is used for logging. 

default: script name, got from $0, split on '/';

=head3 B<do_not_close_fh>

Skips the close and re-open filehandles phase of initialization. This means that
the tie-to-syslog part will be skipped as well. 

default: C<undef> - close all filehandles; if possible, tie STDOUT and STDERR
to syslog.

=head3 B<do_not_tie_stdhandles> 

Define this to skip the tying part (STDIN/STDERR will still be closed, though). 
This is implicit if I<do_not_close_fh> was specified, or if both STDIN/STDERR 
were included in I<keep> array (see I<keep> option for details).

    # close both stdhandles and reopen them on /dev/null
    Script::Daemonizer::daemonize(
        name                  => 'Sort of a daemon',
        do_not_tie_stdhandles => 1,
    );
    open(STDOUT, '>', '/dev/null') or die "Cannot reopen STDOUT on /dev/null: $!"
    open(STDERR, '>', '/dev/null') or die "Cannot reopen STDERR on /dev/null: $!"

default: C<undef> - tie stdhandles so that output will go to syslog.

=head3 B<keep>

This option requires a reference to an array containing the filehandles to be
kept open, or the corresponding number (as returned by C<fileno()>). It is
ingored if I<do_not_close_fh> was specified (because redundant).

If STDOUT/STDERR (or the corresponding file descriptor: 1 or 2) were specified,
then that handle would not be closed and, consequently, not tied to Syslog. 
To tie just one of the two filehandles, specify the other in I<keep> and then
close it (or keep it open, or whatever you prefer):

    # Tie just STDERR to syslog, discard STDOUT:
    Script::Daemonizer::daemonize(
        name => 'Sort of a daemon',
        keep => [ 1 ],
    );
    open(STDOUT, '>', '/dev/null') or die "Cannot reopen STDOUT on /dev/null: $!"

default: C<undef> - close all filehandles.

=head3 B<pidfile>

This will try to write process's pid to the specified file, once the
initialization is complete. 

    Script::Daemonizer::daemonize(
        name    => 'A new daemon',
        pidfile => '/var/run/anewdaemon.pid',
    );

This is also an implicit method to B<lock>: the pidfile will be opened (created
if not found) and then kept open from the daemon. C<flock()> will be called on
the file, so that no other instance of the daemon could overwrite it (it will be
still writable from the rest of the world, though). This provides three
advantages: 

=over 4

=item * no other instances of the same daemon will overwrite the pidfile on
purpose;

=item * the pid file will serve as a lock file, ensuring no other instances of
the same daemon will start;

=item * an C<fuser> on the pidfile will reveal the daemon's pid. If the daemon
is not running, the pidfile will not be in use by any process (hopefully).

=back

=head3 B<umask>

Set the specified umask.

default: 0

=head3 B<working_dir>

Try to C<chdir()> to the specified directory.

default: '/'

=head2 LOCKING

If you want to be sure no multiple instances of your daemon will be running,
just use I<pidfile> advanced option. See I<pidfile> for details.

=head1 TODO

Some ideas: 

=over 4 

=item * Provide a function to automatically parse command line (via L<Getopt::Long>).

=item * Provide a function to automatically handle configuration file (via 
L<Config::General>).

=item * Provide a restart function.

=item * Let user decide if SIGHUP is handled as a full restart or a 
configuration reload.

=back



=head1 AUTHOR

Giacomo Montagner, C<< <gmork at entirelyunlike.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-script-daemonizer at 
rt.cpan.org>, or through the web interface at 
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Script-Daemonizer>.  I will be
notified, and then you'll automatically be notified of progress on your bug as 
I make changes.



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Script::Daemonizer


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Script-Daemonizer>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Script-Daemonizer>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Script-Daemonizer>

=item * Search CPAN

L<http://search.cpan.org/dist/Script-Daemonizer/>

=back


=head1 ACKNOWLEDGEMENTS

=over 4

=item * S<"Advanced Programming in the UNIX Environment: Second Edition">, 
S<by W. Richard Stevens, Stephen A. Rago>, 
S<Copyright 2005 Addison Wesley Professional>

=item * Part of the code was copy-pasted from Proc::Daemon, by Earl Hood and 
Detlef Pilzecker. 

=back



=head1 LICENSE AND COPYRIGHT

Copyright 2012 Giacomo Montagner.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut


